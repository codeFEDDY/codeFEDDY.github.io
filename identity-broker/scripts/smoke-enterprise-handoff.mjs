const AUTH_ORIGIN = "https://auth.codefeddy.com";
const APP_CONFIG = `${AUTH_ORIGIN}/client-config/neuron7-case`;
const REDIRECT_URI = "https://n7crm.codefeddy.com/auth/callback";
const CLIENT_ID = "https://auth.codefeddy.com/client/clintware-web";
const RESOURCE = `${AUTH_ORIGIN}/userinfo`;

function valueFromHtml(html, name) {
  const match = html.match(new RegExp(`name=["']${name}["']\\s+value=["']([^"']+)["']`));
  if (!match) throw new Error(`Missing ${name} in consent page`);
  return match[1].replace(/&amp;/g, "&").replace(/&#39;/g, "'").replace(/&quot;/g, '"');
}

async function consent(provider, label) {
  const url = new URL(`${AUTH_ORIGIN}/authorize`);
  url.search = new URLSearchParams({
    response_type: "code",
    client_id: CLIENT_ID,
    redirect_uri: REDIRECT_URI,
    scope: "identity email profile",
    state: `ci-${provider}-smoke`,
    code_challenge: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    code_challenge_method: "S256",
    resource: RESOURCE,
  }).toString();

  const first = await fetch(url, { redirect: "manual" });
  if (first.status !== 200) throw new Error(`${label} consent page returned HTTP ${first.status}`);
  const cookie = String(first.headers.get("set-cookie") || "").split(";")[0];
  if (!cookie.startsWith("__Host-clintware-oauth-bind=")) throw new Error(`${label} consent cookie missing`);
  const html = await first.text();
  if (!html.includes(`Continue with ${label}`)) throw new Error(`${label} provider button missing`);

  const form = new URLSearchParams({
    transaction: valueFromHtml(html, "transaction"),
    csrf: valueFromHtml(html, "csrf"),
    decision: `approve:${provider}`,
  });
  const second = await fetch(`${AUTH_ORIGIN}/authorize`, {
    method: "POST",
    redirect: "manual",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      cookie,
    },
    body: form,
  });
  if (second.status !== 302) throw new Error(`${label} handoff returned HTTP ${second.status}`);
  const location = second.headers.get("location");
  if (!location) throw new Error(`${label} handoff location missing`);
  return new URL(location);
}

function verifyPkce(url, label) {
  if (url.protocol !== "https:") throw new Error(`${label} handoff is not HTTPS`);
  if (url.searchParams.get("response_type") !== "code") throw new Error(`${label} is not using authorization code flow`);
  if (url.searchParams.get("code_challenge_method") !== "S256") throw new Error(`${label} is not using PKCE S256`);
  if (!url.searchParams.get("code_challenge") || !url.searchParams.get("state") || !url.searchParams.get("nonce")) {
    throw new Error(`${label} handoff is missing PKCE/state/nonce`);
  }
  if (url.searchParams.has("client_secret")) throw new Error(`${label} leaked a client secret into the front channel`);
}

const response = await fetch(APP_CONFIG);
if (!response.ok) throw new Error(`Client config returned HTTP ${response.status}`);
const config = await response.json();
const active = new Set((config.configured_identity_providers || []).map((x) => x.id));

if (active.has("microsoft")) {
  const url = await consent("microsoft", "Microsoft");
  verifyPkce(url, "Microsoft");
  if (url.hostname !== "login.microsoftonline.com") throw new Error("Microsoft handoff host mismatch");
  console.log("Microsoft Entra PKCE handoff verified.");
} else {
  console.log("Microsoft Entra is not active for the restricted app; a pinned tenant GUID and client configuration are required.");
}

if (active.has("okta")) {
  const issuer = new URL(String(process.env.OKTA_OIDC_ISSUER || ""));
  const url = await consent("okta", "Okta");
  verifyPkce(url, "Okta");
  if (url.origin !== issuer.origin) throw new Error("Okta handoff origin mismatch");
  console.log("Okta PKCE handoff verified.");
} else {
  console.log("Okta is not active; issuer/client configuration remains optional.");
}

