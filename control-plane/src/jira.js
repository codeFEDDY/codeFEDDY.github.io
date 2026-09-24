const AUTH_URL = "https://auth.atlassian.com/authorize";
const TOKEN_URL = "https://auth.atlassian.com/oauth/token";
const API_ORIGIN = "https://api.atlassian.com";
const CALLBACK_URL = "https://mcp.codefeddy.com/api/v1/jira/oauth/callback";
const SCOPES = ["read:jira-work", "read:jira-user", "write:jira-work", "read:confluence-content.all", "write:confluence-content", "read:confluence-space.summary", "write:confluence-space", "offline_access"];
const STATE_TTL_MS = 10 * 60 * 1000;
const te = new TextEncoder();
const td = new TextDecoder();

const json = (value, status = 200, extra = {}) => new Response(JSON.stringify(value), {
  status,
  headers: {"content-type":"application/json; charset=utf-8","cache-control":"no-store",...extra}
});

function base64url(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
function fromBase64url(value) {
  const normalized = String(value || "").replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - normalized.length % 4) % 4);
  const binary = atob(padded);
  return Uint8Array.from(binary, c => c.charCodeAt(0));
}
function randomToken(bytes = 24) {
  const value = new Uint8Array(bytes);
  crypto.getRandomValues(value);
  return base64url(value);
}
async function cryptoKey(env, purpose) {
  const secret = String(env.JIRA_TOKEN_ENCRYPTION_KEY || env.CONTROL_PLANE_ADMIN_TOKEN || env.CONTROL_PLANE_MCP_TOKEN || "");
  if (!secret) throw new Error("jira_encryption_secret_missing");
  const raw = await crypto.subtle.digest("SHA-256", te.encode(`clintware-jira:\0${purpose}:\0${secret}`));
  return crypto.subtle.importKey("raw", raw, {name:"AES-GCM"}, false, ["encrypt","decrypt"]);
}
async function seal(env, value, purpose) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const key = await cryptoKey(env, purpose);
  const cipher = await crypto.subtle.encrypt(
    {name:"AES-GCM",iv,additionalData:te.encode(`clintware-jira:${purpose}:v1`)},
    key,
    te.encode(JSON.stringify(value))
  );
  return `${base64url(iv)}.${base64url(new Uint8Array(cipher))}`;
}
async function unseal(env, value, purpose) {
  const [ivPart,cipherPart] = String(value || "").split(".");
  if (!ivPart || !cipherPart) throw new Error("invalid_jira_envelope");
  const key = await cryptoKey(env, purpose);
  const clear = await crypto.subtle.decrypt(
    {name:"AES-GCM",iv:fromBase64url(ivPart),additionalData:te.encode(`clintware-jira:${purpose}:v1`)},
    key,
    fromBase64url(cipherPart)
  );
  return JSON.parse(td.decode(clear));
}
function registryHub(env) {
  return env.REGISTRY_HUB.getByName("registry:v1");
}
async function loadStoredGrant(env) {
  const r = await registryHub(env).fetch("https://internal/jira-grant");
  if (!r.ok) return null;
  const body = await r.json();
  if (!body?.sealed_grant) return null;
  try {
    const grant = await unseal(env, body.sealed_grant, "grant");
    return {...grant, sites:Array.isArray(body.sites)?body.sites:grant.sites||[], updated_at:body.updated_at||null};
  } catch {
    return null;
  }
}
async function saveGrant(env, grant) {
  const safeSites = (grant.sites || []).map(s => ({
    id:String(s.id || ""),
    url:String(s.url || ""),
    name:String(s.name || ""),
    scopes:Array.isArray(s.scopes)?s.scopes.map(String):[],
    avatarUrl:String(s.avatarUrl || "")
  }));
  const sealed = await seal(env, {...grant,sites:safeSites}, "grant");
  const r = await registryHub(env).fetch(new Request("https://internal/jira-grant", {
    method:"POST",
    headers:{"content-type":"application/json"},
    body:JSON.stringify({sealed_grant:sealed,sites:safeSites,scopes:grant.scope||SCOPES.join(" ")})
  }));
  return r.ok;
}
async function clearGrant(env) {
  return registryHub(env).fetch(new Request("https://internal/jira-grant",{method:"DELETE"}));
}
async function tokenRequest(env, body) {
  const response = await fetch(TOKEN_URL, {
    method:"POST",
    headers:{"content-type":"application/json","accept":"application/json"},
    body:JSON.stringify(body)
  });
  const data = await response.json().catch(() => ({}));
  return {ok:response.ok,status:response.status,data};
}
async function accessibleResources(accessToken) {
  const r = await fetch(`${API_ORIGIN}/oauth/token/accessible-resources`, {
    headers:{"authorization":`Bearer ${accessToken}`,"accept":"application/json"}
  });
  const data = await r.json().catch(() => []);
  if (!r.ok) return {ok:false,status:r.status,sites:[]};
  return {ok:true,status:r.status,sites:Array.isArray(data)?data:[]};
}
async function freshAccessToken(env, forceRefresh = false) {
  const grant = await loadStoredGrant(env);
  if (!grant?.refresh_token && !grant?.access_token) return {ok:false,error:"jira_not_connected"};
  const stillFresh = Number(grant.expires_at || 0) > Date.now() + 60_000;
  if (!forceRefresh && stillFresh && grant.access_token) return {ok:true,access_token:grant.access_token,grant};

  if (!grant.refresh_token) return {ok:false,error:"jira_refresh_token_missing"};
  const refreshed = await tokenRequest(env, {
    grant_type:"refresh_token",
    client_id:String(env.ATLASSIAN_CLIENT_ID || ""),
    client_secret:String(env.ATLASSIAN_CLIENT_SECRET || ""),
    refresh_token:grant.refresh_token
  });
  if (!refreshed.ok || !refreshed.data?.access_token) {
    return {ok:false,error:"jira_refresh_failed",status:refreshed.status};
  }
  const next = {
    ...grant,
    access_token:refreshed.data.access_token,
    refresh_token:refreshed.data.refresh_token || grant.refresh_token,
    scope:String(refreshed.data.scope || grant.scope || SCOPES.join(" ")),
    expires_at:Date.now() + Number(refreshed.data.expires_in || 3600) * 1000,
    token_type:String(refreshed.data.token_type || "Bearer"),
    refreshed_at:new Date().toISOString()
  };
  await saveGrant(env,next);
  return {ok:true,access_token:next.access_token,grant:next};
}
function selectSite(grant, cloudId) {
  const sites = Array.isArray(grant?.sites)?grant.sites:[];
  if (cloudId) {
    const site = sites.find(x => String(x.id) === String(cloudId));
    return site ? {ok:true,site} : {ok:false,error:"jira_cloud_id_not_authorized",sites};
  }
  if (sites.length === 1) return {ok:true,site:sites[0]};
  if (sites.length === 0) return {ok:false,error:"jira_no_accessible_sites",sites:[]};
  return {ok:false,error:"jira_cloud_id_required",sites};
}
async function callJira(env, {cloud_id,method="GET",path,body}) {
  let auth = await freshAccessToken(env,false);
  if (!auth.ok) return auth;
  let selected = selectSite(auth.grant,cloud_id);
  if (!selected.ok) return selected;

  const doFetch = token => fetch(
    `${API_ORIGIN}/ex/jira/${encodeURIComponent(selected.site.id)}/rest/api/3/${String(path||"").replace(/^\/+/, "")}`,
    {
      method,
      headers:{
        "authorization":`Bearer ${token}`,
        "accept":"application/json",
        ...(body===undefined?{}:{"content-type":"application/json"})
      },
      body:body===undefined?undefined:JSON.stringify(body)
    }
  );

  let response = await doFetch(auth.access_token);
  if (response.status === 401) {
    auth = await freshAccessToken(env,true);
    if (!auth.ok) return auth;
    response = await doFetch(auth.access_token);
  }
  const text = await response.text();
  let data = null;
  try { data = text ? JSON.parse(text) : {}; } catch { data = {text:text.slice(0,8000)}; }
  return {ok:response.ok,status:response.status,site:selected.site,data};
}
function textDoc(value) {
  const text = String(value || "").trim();
  if (!text) return undefined;
  return {type:"doc",version:1,content:[{type:"paragraph",content:[{type:"text",text}]}]};
}
export function jiraConfigured(env) {
  return Boolean(env.ATLASSIAN_CLIENT_ID && env.ATLASSIAN_CLIENT_SECRET && (env.JIRA_TOKEN_ENCRYPTION_KEY || env.CONTROL_PLANE_ADMIN_TOKEN || env.CONTROL_PLANE_MCP_TOKEN));
}
export async function jiraStatus(env) {
  const grant = await loadStoredGrant(env);
  return {
    configured:jiraConfigured(env),
    connected:Boolean(grant?.refresh_token || grant?.access_token),
    callback_url:CALLBACK_URL,
    scopes:SCOPES,
    granted_scope:String(grant?.scope||""),
    confluence_scope_ready:["read:confluence-content.all","read:confluence-space.summary","write:confluence-content","write:confluence-space"].every(scope=>new Set(String(grant?.scope||"").split(/\s+/)).has(scope)),
    sites:(grant?.sites || []).map(s => ({id:s.id,url:s.url,name:s.name,scopes:s.scopes||[]}))
  };
}
export async function jiraBeginOAuth(env, requestedBy = "qq") {
  if (!jiraConfigured(env)) return {ok:false,error:"jira_oauth_not_configured",callback_url:CALLBACK_URL};
  const state = await seal(env,{
    kind:"jira-oauth",
    nonce:randomToken(),
    requested_by:String(requestedBy || "qq").slice(0,120),
    created_at:Date.now()
  },"state");
  const url = new URL(AUTH_URL);
  url.searchParams.set("audience","api.atlassian.com");
  url.searchParams.set("client_id",String(env.ATLASSIAN_CLIENT_ID));
  url.searchParams.set("scope",SCOPES.join(" "));
  url.searchParams.set("redirect_uri",CALLBACK_URL);
  url.searchParams.set("state",state);
  url.searchParams.set("response_type","code");
  url.searchParams.set("prompt","consent");
  return {ok:true,authorize_url:url.toString(),callback_url:CALLBACK_URL,scopes:SCOPES};
}
export async function jiraFinishOAuth(request, env) {
  const url = new URL(request.url);
  const upstreamError = String(url.searchParams.get("error") || "");
  if (upstreamError) return json({error:"jira_authorization_failed",atlassian_error:upstreamError},400);
  const code = String(url.searchParams.get("code") || "");
  const rawState = String(url.searchParams.get("state") || "");
  if (!code || !rawState) return json({error:"missing_jira_authorization_response"},400);

  let state = null;
  try { state = await unseal(env,rawState,"state"); } catch {}
  const age = state ? Date.now() - Number(state.created_at || 0) : Infinity;
  if (!state || state.kind !== "jira-oauth" || !Number.isFinite(age) || age < 0 || age > STATE_TTL_MS) {
    return json({error:"jira_authorization_state_expired"},400);
  }

  const exchanged = await tokenRequest(env,{
    grant_type:"authorization_code",
    client_id:String(env.ATLASSIAN_CLIENT_ID || ""),
    client_secret:String(env.ATLASSIAN_CLIENT_SECRET || ""),
    code,
    redirect_uri:CALLBACK_URL
  });
  if (!exchanged.ok || !exchanged.data?.access_token) {
    return json({error:"jira_token_exchange_failed",status:exchanged.status},502);
  }
  const resources = await accessibleResources(exchanged.data.access_token);
  if (!resources.ok) return json({error:"jira_accessible_resources_failed",status:resources.status},502);

  const grant = {
    access_token:exchanged.data.access_token,
    refresh_token:String(exchanged.data.refresh_token || ""),
    token_type:String(exchanged.data.token_type || "Bearer"),
    scope:String(exchanged.data.scope || SCOPES.join(" ")),
    expires_at:Date.now() + Number(exchanged.data.expires_in || 3600) * 1000,
    sites:resources.sites,
    connected_at:new Date().toISOString(),
    requested_by:state.requested_by
  };
  if (!grant.refresh_token) return json({error:"jira_refresh_token_missing",hint:"Ensure offline_access is granted in the Atlassian authorization."},502);
  await saveGrant(env,grant);

  const sites = resources.sites.map(s => ({id:s.id,name:s.name,url:s.url}));
  const page = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Jira connected</title><style>body{font-family:system-ui;background:#071018;color:#edf5f8;display:grid;place-items:center;min-height:100vh;margin:0}.card{max-width:620px;padding:32px;border:1px solid #315064;background:#0c1620}h1{margin-top:0;color:#68dfff}code{color:#7ce4b4}</style></head><body><div class="card"><h1>Jira connected to Clintware</h1><p>The Atlassian grant is stored server-side in the CodeFEDDY Control Plane. qq receives capabilities, not Jira credentials.</p><p>Accessible Jira site count: <code>${sites.length}</code></p><p>You can close this tab and return to qq.</p></div></body></html>`;
  return new Response(page,{status:200,headers:{"content-type":"text/html; charset=utf-8","cache-control":"no-store","x-content-type-options":"nosniff"}});
}
export async function jiraDisconnect(env) {
  const r = await clearGrant(env);
  return {ok:r.ok};
}
export async function jiraSites(env) {
  const auth = await freshAccessToken(env,false);
  if (!auth.ok) return auth;
  const resources = await accessibleResources(auth.access_token);
  if (!resources.ok) return {ok:false,error:"jira_accessible_resources_failed",status:resources.status};
  const grant = {...auth.grant,sites:resources.sites};
  await saveGrant(env,grant);
  return {ok:true,sites:resources.sites.map(s=>({id:s.id,name:s.name,url:s.url,scopes:s.scopes||[]}))};
}
export async function jiraProjects(env,{cloud_id}) {
  const r = await callJira(env,{cloud_id,path:"project/search?maxResults=100&orderBy=name"});
  if (!r.ok) return r;
  return {ok:true,site:r.site,projects:(r.data?.values||[]).map(p=>({id:p.id,key:p.key,name:p.name,projectTypeKey:p.projectTypeKey,simplified:p.simplified}))};
}
export async function jiraSearch(env,{cloud_id,jql,max_results=50,fields}) {
  const safeFields = Array.isArray(fields)&&fields.length?fields.slice(0,50):["summary","status","assignee","priority","issuetype","project","updated"];
  const r = await callJira(env,{cloud_id,method:"POST",path:"search/jql",body:{jql:String(jql||""),maxResults:Math.max(1,Math.min(100,Number(max_results)||50)),fields:safeFields}});
  if (!r.ok) return r;
  return {ok:true,site:r.site,...r.data};
}
export async function jiraGetIssue(env,{cloud_id,issue_key,fields}) {
  const params = new URLSearchParams();
  if (Array.isArray(fields)&&fields.length) params.set("fields",fields.slice(0,50).join(","));
  const suffix = params.toString()?`?${params}`:"";
  const r = await callJira(env,{cloud_id,path:`issue/${encodeURIComponent(issue_key)}${suffix}`});
  return r.ok?{ok:true,site:r.site,issue:r.data}:r;
}
export async function jiraCreateIssue(env,{cloud_id,project_key,summary,issue_type,description,labels,assignee_account_id}) {
  const fields = {
    project:{key:String(project_key)},
    summary:String(summary),
    issuetype:{name:String(issue_type)}
  };
  const doc = textDoc(description);
  if (doc) fields.description = doc;
  if (Array.isArray(labels)&&labels.length) fields.labels = labels.slice(0,50).map(String);
  if (assignee_account_id) fields.assignee = {accountId:String(assignee_account_id)};
  const r = await callJira(env,{cloud_id,method:"POST",path:"issue",body:{fields}});
  return r.ok?{ok:true,site:r.site,issue:r.data}:r;
}
export async function jiraUpdateIssue(env,{cloud_id,issue_key,summary,description,labels,assignee_account_id}) {
  const fields = {};
  if (summary !== undefined) fields.summary = String(summary);
  if (description !== undefined) fields.description = textDoc(description) || null;
  if (labels !== undefined) fields.labels = Array.isArray(labels)?labels.slice(0,50).map(String):[];
  if (assignee_account_id !== undefined) fields.assignee = assignee_account_id?{accountId:String(assignee_account_id)}:null;
  if (!Object.keys(fields).length) return {ok:false,error:"jira_no_update_fields"};
  const r = await callJira(env,{cloud_id,method:"PUT",path:`issue/${encodeURIComponent(issue_key)}`,body:{fields}});
  return r.ok?{ok:true,site:r.site,issue_key,status:r.status}:r;
}
export async function jiraAddComment(env,{cloud_id,issue_key,comment}) {
  const body = textDoc(comment);
  if (!body) return {ok:false,error:"jira_comment_required"};
  const r = await callJira(env,{cloud_id,method:"POST",path:`issue/${encodeURIComponent(issue_key)}/comment`,body:{body}});
  return r.ok?{ok:true,site:r.site,comment:r.data}:r;
}
export async function jiraTransitions(env,{cloud_id,issue_key}) {
  const r = await callJira(env,{cloud_id,path:`issue/${encodeURIComponent(issue_key)}/transitions`});
  return r.ok?{ok:true,site:r.site,transitions:r.data?.transitions||[]}:r;
}
export async function jiraTransitionIssue(env,{cloud_id,issue_key,transition_id}) {
  const r = await callJira(env,{cloud_id,method:"POST",path:`issue/${encodeURIComponent(issue_key)}/transitions`,body:{transition:{id:String(transition_id)}}});
  return r.ok?{ok:true,site:r.site,issue_key,transition_id:String(transition_id),status:r.status}:r;
}

export async function atlassianAccessToken(env, forceRefresh = false) {
  return freshAccessToken(env, forceRefresh);
}
export function atlassianRequiredScopes() {
  return [...SCOPES];
}

