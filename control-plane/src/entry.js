import core, { RegistryHub, ProductHub } from "./index.js";
import { isMcpOAuthRoute, mcpOAuthProvider } from "./mcp-oauth.js";

export { RegistryHub, ProductHub };

const JSON_HEADERS = {"content-type":"application/json; charset=utf-8","cache-control":"no-store"};
const json = (value,status=200,extra={}) => new Response(JSON.stringify(value),{status,headers:{...JSON_HEADERS,...extra}});
const bearer = (request) => {
  const h=request.headers.get("authorization")||"";
  return h.toLowerCase().startsWith("bearer ") ? h.slice(7).trim() : "";
};
const sha256 = async (s) => {
  const b=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(String(s||"")));
  return [...new Uint8Array(b)].map(x=>x.toString(16).padStart(2,"0")).join("");
};
const safeEq = async (a,b) => {
  if(!a||!b)return false;
  const [x,y]=await Promise.all([sha256(a),sha256(b)]);
  return x===y;
};

function normalizeApiKeyAuth(request){
  if(request.headers.get("authorization")) return request;
  const apiKey=request.headers.get("x-api-key")||request.headers.get("api-key")||"";
  if(!apiKey) return request;
  const headers=new Headers(request.headers);
  headers.set("authorization",`Bearer ${apiKey.trim()}`);
  return new Request(request,{headers});
}

const VIDCRM_MANIFEST = {
  product:"vidcrm",
  environment:"demo",
  version:1,
  repo:{
    owner:"codeFEDDY",
    name:"codeFEDDY.github.io",
    default_branch:"main",
    read:true,
    write_prefixes:["vidcrm-worker/","control-plane/manifests/vidcrm.json"],
    allowed_workflows:["deploy-vidcrm.yml"]
  },
  dns:{allowed_names:["vidcrmdemo.codefeddy.com"]},
  capabilities:[
    "repo.read:codeFEDDY.github.io",
    "repo.write:vidcrm-worker/**",
    "deployment.read",
    "deployment.execute:vidcrm",
    "dns.ensure:vidcrmdemo.codefeddy.com",
    "analytics.write:vidcrm",
    "analytics.read:vidcrm",
    "research.invoke",
    "cache.read:vidcrm",
    "cache.write:vidcrm"
  ],
  deny:[
    "secrets.read",
    "billing.manage",
    "repo.delete",
    "repo.write:unrelated/**",
    "infrastructure.admin:*"
  ],
  telemetry_namespace:"vidcrm"
};

function trustedVidcrmBinding(request){
  if(request.headers.get("cf-connecting-ip")) return false;
  return (request.headers.get("cf-worker")||"").trim().toLowerCase()==="clintware-vidcrm-fluid-system";
}

async function bootstrapVidcrmService(request,env){
  if(!trustedVidcrmBinding(request)) return request;
  const url=new URL(request.url);
  if(url.pathname!=="/api/v1/research"&&url.pathname!=="/api/v1/events") return request;

  const registry=env.REGISTRY_HUB.getByName("registry:v1");
  await registry.fetch(new Request("https://internal/register",{
    method:"POST",
    headers:{"content-type":"application/json"},
    body:JSON.stringify(VIDCRM_MANIFEST)
  }));

  const token=crypto.randomUUID()+crypto.randomUUID();
  const token_hash=await sha256(token);
  await registry.fetch(new Request("https://internal/client",{
    method:"POST",
    headers:{"content-type":"application/json"},
    body:JSON.stringify({product:"vidcrm",token_hash,scopes:VIDCRM_MANIFEST.capabilities})
  }));

  const headers=new Headers(request.headers);
  headers.set("authorization",`Bearer ${token}`);
  return new Request(request,{headers});
}

const ADMIN_ONLY_REST = new Set([
  "/api/v1/repo/branch",
  "/api/v1/repo/write",
  "/api/v1/deploy",
  "/api/v1/dns/ensure"
]);

export default {
  async fetch(request,env,ctx){
    request=normalizeApiKeyAuth(request);
    request=await bootstrapVidcrmService(request,env);
    const url=new URL(request.url);

    // Keep existing static MCP credentials fully backward compatible. If the
    // core rejects /mcp as unauthenticated, hand the same request to the
    // standards-compliant OAuth provider used by ChatGPT/custom MCP clients.
    if(isMcpOAuthRoute(url)){
      if(url.pathname==="/mcp"){
        const legacy=await core.fetch(request,env,ctx);
        if(legacy.status!==401)return legacy;
      }
      return mcpOAuthProvider.fetch(request,env,ctx);
    }

    // Product runtime tokens are deliberately limited to telemetry/query APIs.
    // Infrastructure mutations are available to trusted MCP clients through the
    // scoped product manifest, or to the administrative REST credential. This
    // prevents a product runtime token from becoming a general infrastructure key.
    if(ADMIN_ONLY_REST.has(url.pathname)){
      const expected=String(env.CONTROL_PLANE_ADMIN_TOKEN||"");
      if(!expected||!await safeEq(bearer(request),expected)){
        return json({
          error:"admin_only_rest_action",
          message:"Infrastructure mutations must use the authenticated Clintware MCP control plane or an administrative credential."
        },403);
      }
    }

    return core.fetch(request,env,ctx);
  },
  async scheduled(controller,env,ctx){
    if(typeof core.scheduled==="function")return core.scheduled(controller,env,ctx);
  }
};

