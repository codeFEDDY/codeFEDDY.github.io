import { OAuthProvider, AuthorizationError, getOAuthApi } from "@cloudflare/workers-oauth-provider";
import { McpServer } from "@modelcontextprotocol/server";
import { createMcpHandler } from "agents/mcp/server";
import * as oauth from "oauth4webapi";
import { createRemoteJWKSet, jwtVerify } from "jose";
import { z } from "zod";
import { FIRST_PARTY_CLIENT, FIRST_PARTY_APPS, FIRST_PARTY_CLIENT_ID, firstPartyApp, firstPartyAppForRedirectUri, firstPartyClientMetadata } from "./first-party.js";
import {
  beginDelegatedGoogle,
  delegatedGoogleStatus,
  finishDelegatedGoogle,
  internalGoogleAccessToken,
} from "./delegated-google.js";

const VERSION = "2026-09-23.11";
const AUTH_ORIGIN = "https://auth.codefeddy.com";
const USERINFO_RESOURCE = `${AUTH_ORIGIN}/userinfo`;
const SUPPORTED_SCOPES = ["identity", "email", "profile"];
const GOOGLE_ISSUER = new URL("https://accounts.google.com");
const GOOGLE_CALLBACK = `${AUTH_ORIGIN}/callback`;
const GOOGLE_WEB_CLIENT_ID = "378690450945-nnb0d9st2d9s5lj2alt7q1hdm3pfige7.apps.googleusercontent.com";
const TX_TTL_SECONDS = 600;
const BIND_COOKIE = "__Host-clintware-oauth-bind";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MICROSOFT_CONSUMER_TENANT_ID = "9188040d-6c67-4c5b-b112-36a304b66dad";
const TOKEN_AUTH_METHODS = new Set(["none", "client_secret_basic", "client_secret_post"]);
const JSON_HEADERS = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
  pragma: "no-cache",
};

const json = (value, status = 200, extra = {}) =>
  new Response(JSON.stringify(value), { status, headers: { ...JSON_HEADERS, ...extra } });

const te = new TextEncoder();
const td = new TextDecoder();

function base64url(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function fromBase64url(value) {
  const normalized = String(value || "").replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
  const binary = atob(padded);
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

function randomToken(bytes = 32) {
  const value = new Uint8Array(bytes);
  crypto.getRandomValues(value);
  return base64url(value);
}

async function sha256(value) {
  const digest = await crypto.subtle.digest("SHA-256", te.encode(String(value || "")));
  return base64url(new Uint8Array(digest));
}

async function stateCryptoKey(env) {
  const secret = String(env.OAUTH_STATE_SECRET || env.CONTROL_PLANE_MCP_TOKEN || "");
  if (!secret) throw new Error("oauth_state_secret_not_configured");
  const raw = await crypto.subtle.digest(
    "SHA-256",
    te.encode(`clintware-oauth-transaction-v2\0${secret}`),
  );
  return crypto.subtle.importKey("raw", raw, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}

async function seal(env, value) {
  const iv = new Uint8Array(12);
  crypto.getRandomValues(iv);
  const key = await stateCryptoKey(env);
  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: te.encode("clintware-oauth-txn-v1") },
    key,
    te.encode(JSON.stringify(value)),
  );
  return `${base64url(iv)}.${base64url(new Uint8Array(ciphertext))}`;
}

async function unseal(env, value) {
  const [ivPart, cipherPart] = String(value || "").split(".");
  if (!ivPart || !cipherPart) throw new Error("invalid_transaction_envelope");
  const key = await stateCryptoKey(env);
  const clear = await crypto.subtle.decrypt(
    {
      name: "AES-GCM",
      iv: fromBase64url(ivPart),
      additionalData: te.encode("clintware-oauth-txn-v1"),
    },
    key,
    fromBase64url(cipherPart),
  );
  return JSON.parse(td.decode(clear));
}

function cookieValue(request, name) {
  const raw = request.headers.get("cookie") || "";
  for (const part of raw.split(";")) {
    const idx = part.indexOf("=");
    if (idx < 0) continue;
    if (part.slice(0, idx).trim() === name) return decodeURIComponent(part.slice(idx + 1).trim());
  }
  return "";
}

function setBindingCookie(value) {
  return `${BIND_COOKIE}=${encodeURIComponent(value)}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=${TX_TTL_SECONDS}`;
}

function clearBindingCookie() {
  return `${BIND_COOKIE}=; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=0`;
}

function htmlEscape(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function html(body, status = 200, extra = {}, formOrigins = []) {
  const safeOrigins = [...new Set(formOrigins.map((value) => {
    try { return new URL(value).origin; } catch { return ""; }
  }).filter(Boolean))];
  const formAction = ["'self'", ...safeOrigins].join(" ");
  const headers = new Headers({
    "content-type": "text/html; charset=utf-8",
    "cache-control": "no-store",
    pragma: "no-cache",
    "content-security-policy": `default-src 'none'; style-src 'unsafe-inline'; form-action ${formAction}; base-uri 'none'; frame-ancestors 'none'`,
    "x-frame-options": "DENY",
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
  });
  for (const [key, value] of Object.entries(extra)) {
    if (key.toLowerCase() === "set-cookie") {
      for (const cookie of (Array.isArray(value) ? value : [value])) headers.append("set-cookie", cookie);
    } else {
      headers.set(key, String(value));
    }
  }
  return new Response(body, { status, headers });
}

function googleClientId(_env) {
  return GOOGLE_WEB_CLIENT_ID;
}

function oauthConfigured(env) {
  return Boolean(env.OAUTH_KV && googleClientId(env) && (env.OAUTH_STATE_SECRET || env.CONTROL_PLANE_MCP_TOKEN));
}


function cleanIssuer(value) {
  const raw = String(value || "").trim();
  if (!raw) return "";
  try {
    const url = new URL(raw);
    if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash) return "";
    return url.href.replace(/\/$/, "");
  } catch {
    return "";
  }
}

function normalizeTokenAuthMethod(value, fallback) {
  const method = String(value || fallback || "").trim().toLowerCase();
  return TOKEN_AUTH_METHODS.has(method) ? method : "";
}

function microsoftTenantPinned(value) {
  const tenant = String(value || "").trim();
  return UUID_RE.test(tenant) && tenant.toLowerCase() !== MICROSOFT_CONSUMER_TENANT_ID;
}

function clientAuthenticationConfigured(method, clientSecret) {
  return method === "none" || Boolean(clientSecret);
}

function upstreamProviders(env) {
  const microsoftTenant = String(env.MICROSOFT_ENTRA_TENANT || "organizations").trim() || "organizations";
  const microsoftClientId = String(env.MICROSOFT_ENTRA_CLIENT_ID || "").trim();
  const microsoftClientSecret = String(env.MICROSOFT_ENTRA_CLIENT_SECRET || "").trim();
  const microsoftTokenAuthMethod = normalizeTokenAuthMethod(
    env.MICROSOFT_ENTRA_TOKEN_AUTH_METHOD,
    microsoftClientSecret ? "client_secret_post" : "none",
  );
  const oktaIssuer = cleanIssuer(env.OKTA_OIDC_ISSUER);
  const oktaClientId = String(env.OKTA_OIDC_CLIENT_ID || "").trim();
  const oktaClientSecret = String(env.OKTA_OIDC_CLIENT_SECRET || "").trim();
  const oktaTokenAuthMethod = normalizeTokenAuthMethod(
    env.OKTA_OIDC_TOKEN_AUTH_METHOD,
    oktaClientSecret ? "client_secret_basic" : "none",
  );

  return [
    {
      id: "google",
      label: "Google",
      issuer: "https://accounts.google.com",
      clientId: googleClientId(env),
      callback: GOOGLE_CALLBACK,
      configured: Boolean(googleClientId(env)),
      mode: "id_token_form_post",
    },
    {
      id: "microsoft",
      label: "Microsoft",
      issuer: `https://login.microsoftonline.com/${encodeURIComponent(microsoftTenant)}/v2.0`,
      clientId: microsoftClientId,
      clientSecret: microsoftClientSecret,
      callback: `${AUTH_ORIGIN}/callback/microsoft`,
      configured: Boolean(
        microsoftClientId &&
        microsoftTokenAuthMethod &&
        clientAuthenticationConfigured(microsoftTokenAuthMethod, microsoftClientSecret)
      ),
      mode: "code_pkce",
      tenant: microsoftTenant,
      tenantPinned: microsoftTenantPinned(microsoftTenant),
      tokenAuthMethod: microsoftTokenAuthMethod,
    },
    {
      id: "okta",
      label: "Okta",
      issuer: oktaIssuer,
      clientId: oktaClientId,
      clientSecret: oktaClientSecret,
      callback: `${AUTH_ORIGIN}/callback/okta`,
      configured: Boolean(
        oktaIssuer &&
        oktaClientId &&
        oktaTokenAuthMethod &&
        clientAuthenticationConfigured(oktaTokenAuthMethod, oktaClientSecret)
      ),
      mode: "code_pkce",
      issuerPinned: Boolean(oktaIssuer),
      tokenAuthMethod: oktaTokenAuthMethod,
    },
    {
      id: "auth0",
      label: "Auth0",
      issuer: cleanIssuer(env.AUTH0_OIDC_ISSUER),
      clientId: String(env.AUTH0_OIDC_CLIENT_ID || "").trim(),
      clientSecret: String(env.AUTH0_OIDC_CLIENT_SECRET || "").trim(),
      callback: `${AUTH_ORIGIN}/callback/auth0`,
      configured: Boolean(cleanIssuer(env.AUTH0_OIDC_ISSUER) && String(env.AUTH0_OIDC_CLIENT_ID || "").trim()),
      mode: "code_pkce",
      tokenAuthMethod: normalizeTokenAuthMethod(env.AUTH0_OIDC_TOKEN_AUTH_METHOD, "client_secret_post"),
    },
    {
      id: "pingone",
      label: "PingOne",
      issuer: cleanIssuer(env.PINGONE_OIDC_ISSUER),
      clientId: String(env.PINGONE_OIDC_CLIENT_ID || "").trim(),
      clientSecret: String(env.PINGONE_OIDC_CLIENT_SECRET || "").trim(),
      callback: `${AUTH_ORIGIN}/callback/pingone`,
      configured: Boolean(cleanIssuer(env.PINGONE_OIDC_ISSUER) && String(env.PINGONE_OIDC_CLIENT_ID || "").trim()),
      mode: "code_pkce",
      tokenAuthMethod: normalizeTokenAuthMethod(env.PINGONE_OIDC_TOKEN_AUTH_METHOD, "client_secret_basic"),
    },
    {
      id: "oidc",
      label: "Company SSO",
      issuer: cleanIssuer(env.GENERIC_OIDC_ISSUER),
      clientId: String(env.GENERIC_OIDC_CLIENT_ID || "").trim(),
      clientSecret: String(env.GENERIC_OIDC_CLIENT_SECRET || "").trim(),
      callback: `${AUTH_ORIGIN}/callback/oidc`,
      configured: Boolean(cleanIssuer(env.GENERIC_OIDC_ISSUER) && String(env.GENERIC_OIDC_CLIENT_ID || "").trim()),
      mode: "code_pkce",
      tokenAuthMethod: normalizeTokenAuthMethod(env.GENERIC_OIDC_TOKEN_AUTH_METHOD, "client_secret_basic"),
    },
  ];
}

function providerById(env, id) {
  return upstreamProviders(env).find((provider) => provider.id === String(id || "").toLowerCase()) || null;
}

function providerReadyForApp(provider, app) {
  const allowedIds = app?.identityProviders?.length ? [...app.identityProviders] : ["google"];
  if (!provider?.configured || !allowedIds.includes(provider.id)) return false;
  if (provider.id === "microsoft" && app?.allowedEmailDomains?.length && !provider.tenantPinned) return false;
  return true;
}

function allowedProvidersForRequest(env, oauthRequest) {
  const app = firstPartyAppForRedirectUri(oauthRequest.redirectUri);
  return upstreamProviders(env).filter((provider) => providerReadyForApp(provider, app));
}

function providerFormOrigins(providers) {
  return providers.map((provider) => provider.issuer).filter(Boolean);
}

async function oidcDiscovery(provider) {
  if (!provider?.issuer) throw new Error("oidc_issuer_missing");
  const discoveryUrl = provider.issuer.replace(/\/$/, "") + "/.well-known/openid-configuration";
  const response = await fetch(discoveryUrl, {
    headers: { accept: "application/json" },
    cf: { cacheTtl: 300, cacheEverything: true },
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok || !data.authorization_endpoint || !data.token_endpoint || !data.jwks_uri) {
    throw new Error("oidc_discovery_failed:" + provider.id);
  }
  for (const field of ["authorization_endpoint", "token_endpoint", "jwks_uri"]) {
    let endpoint;
    try { endpoint = new URL(data[field]); } catch { throw new Error("oidc_discovery_invalid_endpoint:" + provider.id); }
    if (endpoint.protocol !== "https:") throw new Error("oidc_discovery_insecure_endpoint:" + provider.id);
  }
  if (provider.id !== "microsoft") {
    const discoveredIssuer = cleanIssuer(data.issuer);
    if (!discoveredIssuer || discoveredIssuer !== provider.issuer) {
      throw new Error("oidc_discovery_issuer_mismatch:" + provider.id);
    }
  }
  return data;
}

function validateEnterpriseIssuer(provider, claims, discovery) {
  const issuer = String(claims?.iss || "");
  if (provider.id === "microsoft") {
    const tid = String(claims?.tid || "");
    if (!UUID_RE.test(tid)) return false;
    if (String(provider.tenant || "").toLowerCase() === "organizations" && tid.toLowerCase() === MICROSOFT_CONSUMER_TENANT_ID) return false;
    if (provider.tenantPinned && tid.toLowerCase() !== String(provider.tenant).toLowerCase()) return false;
    return issuer === `https://login.microsoftonline.com/${tid}/v2.0`;
  }
  return Boolean(discovery?.issuer && issuer === String(discovery.issuer));
}

function restrictedApplicationsForDomain(domain) {
  const target = String(domain || "").toLowerCase();
  if (!target) return [];
  return Object.values(FIRST_PARTY_APPS).filter((app) =>
    (app.allowedEmailDomains || []).map((value) => String(value).toLowerCase()).includes(target)
  );
}

function extractUpstreamIdentity(provider, claims) {
  const email = typeof claims.email === "string" && claims.email.includes("@")
    ? claims.email
    : provider.id === "microsoft" && typeof claims.preferred_username === "string" && claims.preferred_username.includes("@")
      ? claims.preferred_username
      : provider.id === "microsoft" && typeof claims.upn === "string" && claims.upn.includes("@")
        ? claims.upn
        : "";
  const explicitVerified = claims.email_verified === true || claims.email_verified === "true";
  const tenantId = provider.id === "microsoft" ? String(claims.tid || "") : "";
  return {
    subject: String(claims.sub || ""),
    email,
    emailVerified: explicitVerified,
    tenantId,
    verificationBasis: explicitVerified
      ? "email_verified_claim"
      : provider.id === "microsoft" && provider.tenantPinned
        ? "microsoft_tenant_subject"
        : "signed_oidc_subject",
    name: typeof claims.name === "string" ? claims.name : "",
    picture: typeof claims.picture === "string" ? claims.picture : "",
  };
}

async function completeUpstreamAuthorization(transaction, provider, identity, env) {
  if (!identity.subject) throw new Error("upstream_subject_missing");
  if (!identity.email) {
    return json({ error: "identity_email_required", provider: provider.id }, 403, { "set-cookie": clearBindingCookie() });
  }

  const application = firstPartyAppForRedirectUri(transaction.oauthRequest.redirectUri);
  const providerAllowed = application?.identityProviders?.length
    ? application.identityProviders.includes(provider.id)
    : provider.id === "google";
  if (!providerAllowed) {
    return json({
      error: "identity_provider_not_allowed_for_application",
      provider: provider.id,
      application: application?.product || "external",
    }, 403, { "set-cookie": clearBindingCookie() });
  }

  const emailLower = identity.email.trim().toLowerCase();
  const emailDomain = emailLower.includes("@") ? emailLower.split("@").pop() : "";
  const microsoftTenantAuthorized = provider.id === "microsoft"
    && provider.tenantPinned
    && UUID_RE.test(identity.tenantId)
    && identity.tenantId.toLowerCase() === String(provider.tenant).toLowerCase();
  const identityAssurance = microsoftTenantAuthorized
    ? "microsoft_tenant_id"
    : identity.emailVerified === true
      ? "verified_email"
      : "oidc_subject";

  if (provider.id !== "microsoft" && identity.emailVerified !== true) {
    return json({ error: "verified_identity_email_required", provider: provider.id }, 403, { "set-cookie": clearBindingCookie() });
  }

  if (provider.id === "microsoft" && application?.allowedEmailDomains?.length && !microsoftTenantAuthorized) {
    return json({
      error: "microsoft_tenant_pin_required_for_restricted_application",
      application: application.product,
    }, 403, { "set-cookie": clearBindingCookie() });
  }

  if (provider.id !== "microsoft") {
    const restrictedApps = restrictedApplicationsForDomain(emailDomain);
    if (restrictedApps.length && !restrictedApps.some((app) => app.product === application?.product)) {
      return json({
        error: "application_not_allowed_for_identity_domain",
        application: application?.product || "external",
        allowed_applications: restrictedApps.map((app) => app.product),
      }, 403, { "set-cookie": clearBindingCookie() });
    }
  }

  if (application?.allowedEmailDomains?.length && provider.id !== "microsoft") {
    const allowedDomains = application.allowedEmailDomains.map((value) => String(value).toLowerCase());
    const allowedEmails = (application.allowedEmails || []).map((value) => String(value).toLowerCase());
    if (!allowedDomains.includes(emailDomain) && !allowedEmails.includes(emailLower)) {
      return json({ error: "identity_not_allowed_for_application", application: application.product }, 403, {
        "set-cookie": clearBindingCookie(),
      });
    }
  }

  const userId = `cw_${(await sha256(`${provider.id}:${identity.subject}`)).slice(0, 40)}`;
  const grantedScopes = transaction.oauthRequest.scope.filter((scope) => SUPPORTED_SCOPES.includes(scope));
  const authResult = await env.OAUTH_PROVIDER.completeAuthorization({
    request: transaction.oauthRequest,
    userId,
    metadata: {
      provider: provider.id,
      upstream: provider.mode,
      application: application?.product || "external",
      verification_basis: identity.verificationBasis,
      tenant_id: identity.tenantId || undefined,
      identity_assurance: identityAssurance,
    },
    scope: grantedScopes,
    props: {
      userId,
      provider: provider.id,
      providerSubject: identity.subject,
      email: identity.email,
      emailVerified: identity.emailVerified === true,
      emailVerificationBasis: identity.verificationBasis,
      tenantId: identity.tenantId || "",
      identityAssurance,
      name: identity.name,
      picture: identity.picture,
      scopes: grantedScopes,
      application: application?.product || "external",
      applicationContext: application?.contextScopes ? [...application.contextScopes] : [],
    },
  });

  const headers = new Headers({ location: authResult.redirectTo, "cache-control": "no-store" });
  headers.append("set-cookie", clearBindingCookie());
  return new Response(null, { status: 302, headers });
}

async function googleAuthorizationServer() {
  const response = await oauth.discoveryRequest(GOOGLE_ISSUER, { algorithm: "oidc" });
  return oauth.processDiscoveryResponse(GOOGLE_ISSUER, response);
}

function googleClient(env) {
  return { client_id: googleClientId(env) };
}

function redirectAuthorizationError(error) {
  if (!(error instanceof AuthorizationError)) throw error;
  if (!error.redirectUri) return html("<h1>Invalid OAuth request</h1><p>The client or redirect URI was not accepted.</p>", 400);
  const redirect = new URL(error.redirectUri);
  redirect.searchParams.set("error", error.code);
  redirect.searchParams.set("error_description", error.description);
  if (error.state) redirect.searchParams.set("state", error.state);
  if (error.issuer) redirect.searchParams.set("iss", error.issuer);
  return Response.redirect(redirect, 302);
}

function denyAuthorization(oauthRequest) {
  const redirect = new URL(oauthRequest.redirectUri);
  redirect.searchParams.set("error", "access_denied");
  redirect.searchParams.set("error_description", "The user denied the authorization request.");
  if (oauthRequest.state) redirect.searchParams.set("state", oauthRequest.state);
  if (oauthRequest.issuer) redirect.searchParams.set("iss", oauthRequest.issuer);
  return Response.redirect(redirect, 302);
}

function consentPage(client, oauthRequest, transactionToken, csrfToken, providers) {
  const labels = {
    identity: "Stable Clintware account identity",
    email: "Verified email address",
    profile: "Display name and profile image",
  };
  const scopes = oauthRequest.scope.filter((scope) => SUPPORTED_SCOPES.includes(scope));
  const scopeList = scopes.map((scope) => `<li><span class="scope">${htmlEscape(scope)}</span><span>${htmlEscape(labels[scope] || scope)}</span></li>`).join("");
  const providerButtons = providers.map((provider) =>
    `<button class="approve provider" name="decision" value="approve:${htmlEscape(provider.id)}" type="submit">Continue with ${htmlEscape(provider.label)}</button>`
  ).join("");
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Continue to Clintware</title>
<style>
:root{color-scheme:dark;--bg:#03070b;--panel:#0a1118;--line:#203344;--text:#f7fbff;--muted:#8ea2b4;--cyan:#57dcff;--mint:#75f2c0}
*{box-sizing:border-box}body{margin:0;min-height:100vh;background:radial-gradient(circle at 50% 21%,#103349 0,#071019 22%,#03070b 52%,#020406 100%);color:var(--text);font-family:Inter,ui-sans-serif,system-ui,-apple-system,Segoe UI,sans-serif}
main{max-width:720px;margin:0 auto;padding:7vh 22px 48px}.brandstage{height:260px;display:grid;place-items:center;position:relative}.eclipse{position:absolute;width:220px;height:220px;border-radius:50%;background:#010204;box-shadow:0 0 8px 1px #8eeaff,0 0 34px 8px #3dd7ff,0 0 78px 20px #168fc4,0 0 120px 35px #0a4d70}.wordmark{position:relative;z-index:2;font-size:clamp(44px,9vw,72px);font-weight:850;letter-spacing:-.055em;text-shadow:0 2px 28px #000}.tm{font-size:.28em;vertical-align:top;margin-left:5px;letter-spacing:0}
.card{position:relative;background:linear-gradient(180deg,#0d1721ee,#071019f4);border:1px solid #294258;border-radius:24px;padding:30px;box-shadow:0 24px 90px #0008,inset 0 1px #ffffff0a;backdrop-filter:blur(18px)}.eyebrow{color:var(--cyan);font:700 11px/1.2 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.2em;text-transform:uppercase}h1{font-size:31px;line-height:1.12;margin:12px 0 10px}.lead{color:#b8c6d2;line-height:1.6;margin:0 0 22px}
ul{list-style:none;padding:0;margin:18px 0;border-top:1px solid var(--line)}li{display:grid;grid-template-columns:110px 1fr;gap:14px;padding:12px 0;border-bottom:1px solid var(--line);color:#a9bac8}.scope{color:var(--mint);font:700 12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}
.actions{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px;margin-top:24px}button{appearance:none;border:1px solid var(--line);border-radius:12px;padding:14px 18px;font-weight:800;font-size:15px;cursor:pointer}.approve{background:#f7fbff;color:#061018;border-color:#f7fbff}.approve:hover{background:#dff7ff}.provider:nth-last-child(2):nth-child(odd){grid-column:1/-1}.deny{grid-column:1/-1;background:#0a141e;color:#c9d6df}.fine{font-size:12px;color:#718697;line-height:1.55;margin:18px 0 0}.secure{display:flex;align-items:center;justify-content:center;gap:8px;color:#8297a9;font-size:12px;margin-top:22px}.dot{width:7px;height:7px;border-radius:50%;background:var(--mint);box-shadow:0 0 12px var(--mint)}
@media(max-width:580px){main{padding-top:18px}.brandstage{height:220px}.eclipse{width:185px;height:185px}.card{padding:22px;border-radius:18px}li{grid-template-columns:90px 1fr}.actions{grid-template-columns:1fr}.provider,.provider:nth-last-child(2):nth-child(odd),.deny{grid-column:1}}
</style></head>
<body><main>
<div class="brandstage"><div class="eclipse" aria-hidden="true"></div><div class="wordmark">Clintware<span class="tm">TM</span></div></div>
<section class="card">
<div class="eyebrow">Clintware Identity</div>
<h1>Continue to ${htmlEscape(client.clientName || "Clintware")}</h1>
<p class="lead">Choose an approved identity provider for this application. Clintware receives only the verified identity claims needed for the permissions shown below and keeps the resulting access scoped to this application.</p>
<ul>${scopeList}</ul>
<form method="post" action="/authorize">
<input type="hidden" name="transaction" value="${htmlEscape(transactionToken)}">
<input type="hidden" name="csrf" value="${htmlEscape(csrfToken)}">
<div class="actions">${providerButtons}<button class="deny" name="decision" value="deny" type="submit">Cancel</button></div>
</form>
<p class="fine">Only configured providers approved for this application are shown. Identity proof does not grant MCP, repository, deployment, DNS, Control Plane, or another Clintware application access unless that application explicitly authorizes it.</p>
</section>
<div class="secure"><span class="dot"></span><span>Secure sign-in · auth.codefeddy.com</span></div>
</main></body></html>`;
}

async function beginConsent(request, env) {
  if (!oauthConfigured(env)) return json({ error: "identity_provider_not_configured" }, 503);
  let oauthRequest;
  try {
    oauthRequest = await env.OAUTH_PROVIDER.parseAuthRequest(request);
  } catch (error) {
    return redirectAuthorizationError(error);
  }
  const client = await env.OAUTH_PROVIDER.lookupClient(oauthRequest.clientId);
  if (!client) return html("<h1>Unknown OAuth client</h1>", 400);
  if (!oauthRequest.scope.includes("identity")) {
    const redirect = new URL(oauthRequest.redirectUri);
    redirect.searchParams.set("error", "invalid_scope");
    redirect.searchParams.set("error_description", "The identity scope is required for Clintware sign-in.");
    if (oauthRequest.state) redirect.searchParams.set("state", oauthRequest.state);
    if (oauthRequest.issuer) redirect.searchParams.set("iss", oauthRequest.issuer);
    return Response.redirect(redirect, 302);
  }

  const csrf = randomToken(24);
  const binding = randomToken(32);
  const transaction = await seal(env, {
    kind: "consent",
    oauthRequest,
    csrfHash: await sha256(csrf),
    bindingHash: await sha256(binding),
    createdAt: Date.now(),
  });
  const app = firstPartyAppForRedirectUri(oauthRequest.redirectUri);
  const displayClient = app ? { ...client, clientName: app.name } : client;
  const providers = allowedProvidersForRequest(env, oauthRequest);
  if (!providers.length) return json({ error: "no_identity_provider_configured_for_application" }, 503);
  return html(consentPage(displayClient, oauthRequest, transaction, csrf, providers), 200, {
    "set-cookie": setBindingCookie(binding),
  }, providerFormOrigins(providers));
}

async function startGoogle(oauthRequest, binding, env) {
  const as = await googleAuthorizationServer();
  if (!as.authorization_endpoint) throw new Error("google_authorization_endpoint_missing");
  const nonce = oauth.generateRandomNonce();
  const state = await seal(env, {
    kind: "google",
    oauthRequest,
    bindingHash: await sha256(binding),
    nonce,
    createdAt: Date.now(),
  });

  const url = new URL(as.authorization_endpoint);
  url.searchParams.set("client_id", googleClientId(env));
  url.searchParams.set("redirect_uri", GOOGLE_CALLBACK);
  url.searchParams.set("response_type", "id_token");
  url.searchParams.set("response_mode", "form_post");
  url.searchParams.set("scope", "openid email profile");
  url.searchParams.set("state", state);
  url.searchParams.set("nonce", nonce);
  const app = firstPartyAppForRedirectUri(oauthRequest.redirectUri);
  if (app?.allowedEmailDomains?.length === 1) url.searchParams.set("hd", app.allowedEmailDomains[0]);
  url.searchParams.set("prompt", "select_account");
  const headers = new Headers({
    location: url.href,
    "cache-control": "no-store",
    "referrer-policy": "no-referrer",
  });
  return new Response(null, { status: 302, headers });
}

async function finishConsent(request, env) {
  if (!oauthConfigured(env)) return json({ error: "identity_provider_not_configured" }, 503);
  const len = Number(request.headers.get("content-length") || 0);
  if (len > 16_384) return json({ error: "request_too_large" }, 413);
  const form = await request.formData();
  const transactionToken = String(form.get("transaction") || "");
  const csrf = String(form.get("csrf") || "");
  const decision = String(form.get("decision") || "");
  if (!transactionToken || !csrf) return json({ error: "invalid_consent_submission" }, 400);
  let transaction = null;
  try {
    transaction = await unseal(env, transactionToken);
  } catch {}
  const age = transaction ? Date.now() - Number(transaction.createdAt || 0) : Infinity;
  if (!transaction || transaction.kind !== "consent" || !Number.isFinite(age) || age < 0 || age > TX_TTL_SECONDS * 1000) {
    return json({ error: "authorization_transaction_expired" }, 400);
  }
  const binding = cookieValue(request, BIND_COOKIE);
  if (!binding || (await sha256(binding)) !== transaction.bindingHash || (await sha256(csrf)) !== transaction.csrfHash) {
    return json({ error: "authorization_transaction_mismatch" }, 400, {
      "set-cookie": clearBindingCookie(),
    });
  }
  if (decision === "deny") return denyAuthorization(transaction.oauthRequest);
  const providerId = decision === "approve" ? "google" : decision.startsWith("approve:") ? decision.slice("approve:".length) : "";
  const allowedProviders = allowedProvidersForRequest(env, transaction.oauthRequest);
  const provider = allowedProviders.find((item) => item.id === providerId);
  if (!provider) return json({
    error: "identity_provider_not_allowed_for_application",
    provider: providerId || "unknown",
  }, 403, { "set-cookie": clearBindingCookie() });
  if (provider.id === "google") return startGoogle(transaction.oauthRequest, binding, env);
  return startEnterpriseOidc(provider, transaction.oauthRequest, binding, env);
}

async function startEnterpriseOidc(provider, oauthRequest, binding, env) {
  if (!provider?.configured || provider.mode !== "code_pkce") {
    return json({ error: "identity_provider_not_configured", provider: provider?.id || "unknown" }, 503);
  }
  const discovery = await oidcDiscovery(provider);
  const nonce = randomToken(24);
  const verifier = randomToken(48);
  const challenge = await sha256(verifier);
  const state = await seal(env, {
    kind: "enterprise_oidc",
    provider: provider.id,
    oauthRequest,
    bindingHash: await sha256(binding),
    nonce,
    verifier,
    createdAt: Date.now(),
  });
  const url = new URL(discovery.authorization_endpoint);
  url.searchParams.set("client_id", provider.clientId);
  url.searchParams.set("redirect_uri", provider.callback);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("scope", "openid email profile");
  url.searchParams.set("state", state);
  url.searchParams.set("nonce", nonce);
  url.searchParams.set("code_challenge", challenge);
  url.searchParams.set("code_challenge_method", "S256");
  if (provider.id === "microsoft") {
    url.searchParams.set("prompt", "select_account");
    const app = firstPartyAppForRedirectUri(oauthRequest.redirectUri);
    if (app?.allowedEmailDomains?.length === 1) url.searchParams.set("domain_hint", app.allowedEmailDomains[0]);
  }
  return new Response(null, {
    status: 302,
    headers: {
      location: url.href,
      "cache-control": "no-store",
      "referrer-policy": "no-referrer",
    },
  });
}

function tokenRequestHeaders(provider) {
  const headers = new Headers({ "content-type": "application/x-www-form-urlencoded", accept: "application/json" });
  if (provider.clientSecret && provider.tokenAuthMethod === "client_secret_basic") {
    headers.set("authorization", "Basic " + btoa(provider.clientId + ":" + provider.clientSecret));
  }
  return headers;
}

async function finishEnterpriseOidc(request, env, providerId) {
  const provider = providerById(env, providerId);
  if (!provider?.configured || provider.mode !== "code_pkce") {
    return json({ error: "identity_provider_not_configured", provider: providerId }, 503);
  }

  let params;
  if (request.method === "POST") {
    const len = Number(request.headers.get("content-length") || 0);
    if (len > 32_768) return json({ error: "request_too_large" }, 413);
    params = await request.formData();
  } else {
    params = new URL(request.url).searchParams;
  }

  const code = String(params.get("code") || "");
  const state = String(params.get("state") || "");
  const upstreamError = String(params.get("error") || "");
  if (upstreamError) {
    return json({
      error: "upstream_authorization_failed",
      provider: provider.id,
      upstream_error: upstreamError,
      description: String(params.get("error_description") || ""),
    }, 400, { "set-cookie": clearBindingCookie() });
  }
  if (!code || !state) return json({ error: "missing_upstream_authorization_response", provider: provider.id }, 400, { "set-cookie": clearBindingCookie() });

  let transaction = null;
  try { transaction = await unseal(env, state); } catch {}
  const age = transaction ? Date.now() - Number(transaction.createdAt || 0) : Infinity;
  if (!transaction || transaction.kind !== "enterprise_oidc" || transaction.provider !== provider.id || !Number.isFinite(age) || age < 0 || age > TX_TTL_SECONDS * 1000) {
    return json({ error: "authorization_transaction_expired", provider: provider.id }, 400, {
      "set-cookie": clearBindingCookie(),
    });
  }

  const binding = cookieValue(request, BIND_COOKIE);
  if (!binding || (await sha256(binding)) !== transaction.bindingHash) {
    return json({ error: "authorization_transaction_mismatch", provider: provider.id }, 400, {
      "set-cookie": clearBindingCookie(),
    });
  }

  const discovery = await oidcDiscovery(provider);
  const body = new URLSearchParams({
    grant_type: "authorization_code",
    client_id: provider.clientId,
    code,
    redirect_uri: provider.callback,
    code_verifier: transaction.verifier,
  });
  if (provider.clientSecret && provider.tokenAuthMethod !== "client_secret_basic") {
    body.set("client_secret", provider.clientSecret);
  }

  const tokenResponse = await fetch(discovery.token_endpoint, {
    method: "POST",
    headers: tokenRequestHeaders(provider),
    body,
  });
  const tokens = await tokenResponse.json().catch(() => ({}));
  if (!tokenResponse.ok || !tokens.id_token) {
    return json({
      error: "upstream_token_exchange_failed",
      provider: provider.id,
      status: tokenResponse.status,
    }, 502, { "set-cookie": clearBindingCookie() });
  }

  const jwks = createRemoteJWKSet(new URL(discovery.jwks_uri));
  const verified = await jwtVerify(tokens.id_token, jwks, {
    audience: provider.clientId,
    clockTolerance: 10,
  });
  const claims = verified.payload;
  if (!validateEnterpriseIssuer(provider, claims, discovery)) {
    return json({ error: "upstream_issuer_mismatch", provider: provider.id }, 403, { "set-cookie": clearBindingCookie() });
  }
  if (claims.nonce !== transaction.nonce) {
    return json({ error: "upstream_nonce_mismatch", provider: provider.id }, 400, { "set-cookie": clearBindingCookie() });
  }

  const identity = extractUpstreamIdentity(provider, claims);
  return completeUpstreamAuthorization(transaction, provider, identity, env);
}

async function finishGoogle(request, env) {
  if (!oauthConfigured(env)) return json({ error: "identity_provider_not_configured" }, 503);
  const len = Number(request.headers.get("content-length") || 0);
  if (len > 32_768) return json({ error: "request_too_large" }, 413);
  const form = await request.formData();
  const state = String(form.get("state") || "");
  const idToken = String(form.get("id_token") || "");
  const upstreamError = String(form.get("error") || "");
  if (upstreamError) {
    return json({
      error: "google_authorization_failed",
      google_error: upstreamError,
      description: String(form.get("error_description") || ""),
    }, 400, { "set-cookie": clearBindingCookie() });
  }
  if (!state || !idToken) return json({ error: "missing_google_identity_response" }, 400, { "set-cookie": clearBindingCookie() });

  let transaction = null;
  try {
    transaction = await unseal(env, state);
  } catch {}
  const age = transaction ? Date.now() - Number(transaction.createdAt || 0) : Infinity;
  if (!transaction || transaction.kind !== "google" || !Number.isFinite(age) || age < 0 || age > TX_TTL_SECONDS * 1000) {
    return json({ error: "authorization_transaction_expired" }, 400, {
      "set-cookie": clearBindingCookie(),
    });
  }

  const as = await googleAuthorizationServer();
  if (!as.jwks_uri) throw new Error("google_jwks_uri_missing");
  const jwks = createRemoteJWKSet(new URL(as.jwks_uri));
  const verified = await jwtVerify(idToken, jwks, {
    issuer: ["https://accounts.google.com", "accounts.google.com"],
    audience: googleClientId(env),
    clockTolerance: 10,
  });
  const claims = verified.payload;
  if (!claims?.sub) throw new Error("google_subject_missing");
  if (claims.nonce !== transaction.nonce) return json({ error: "google_nonce_mismatch" }, 400, { "set-cookie": clearBindingCookie() });

  const provider = providerById(env, "google");
  const identity = extractUpstreamIdentity(provider, claims);
  if (!identity.email || claims.email_verified !== true && claims.email_verified !== "true") {
    return json({ error: "verified_google_email_required" }, 403, { "set-cookie": clearBindingCookie() });
  }
  identity.emailVerified = true;
  identity.verificationBasis = "email_verified_claim";
  return completeUpstreamAuthorization(transaction, provider, identity, env);
}

const userInfoHandler = {
  async fetch(_request, _env, ctx) {
    const props = ctx.props || {};
    const scopes = Array.isArray(props.scopes) ? props.scopes : [];
    if (!props.userId || !scopes.includes("identity")) return json({ error: "insufficient_scope" }, 403);
    const result = {
      sub: props.userId,
      provider: props.provider || "google",
      application: props.application || "external",
      application_context: Array.isArray(props.applicationContext) ? props.applicationContext : [],
      identity_assurance: props.identityAssurance || "oidc_subject",
    };
    if (scopes.includes("email")) {
      result.email = props.email || "";
      result.email_verified = props.emailVerified === true;
      if (props.tenantId) result.tenant_id = props.tenantId;
    }
    if (scopes.includes("profile")) {
      result.name = props.name || "";
      result.picture = props.picture || "";
    }
    return json(result);
  },
};

function bearer(request) {
  const value = request.headers.get("authorization") || "";
  return value.toLowerCase().startsWith("bearer ") ? value.slice(7).trim() : "";
}

async function secureEq(a, b) {
  if (!a || !b) return false;
  const [x, y] = await Promise.all([sha256(a), sha256(b)]);
  return x === y;
}

function validRedirectUri(value) {
  try {
    const url = new URL(value);
    if (url.username || url.password || url.hash) return false;
    if (url.protocol === "https:") return true;
    return url.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]", "::1"].includes(url.hostname);
  } catch {
    return false;
  }
}

function oauthApi(env) {
  if (!env.OAUTH_KV) throw new Error("oauth_kv_not_configured");
  return getOAuthApi(OAUTH_OPTIONS, env);
}

function publicClient(client) {
  return {
    client_id: client.clientId,
    client_name: client.clientName || "",
    client_uri: client.clientUri || "",
    redirect_uris: client.redirectUris || [],
    token_endpoint_auth_method: client.tokenEndpointAuthMethod || "client_secret_basic",
  };
}


async function firstPartyClientConfig(env, key) {
  const app = firstPartyApp(key);
  if (!app) return null;
  return {
    client_id: FIRST_PARTY_CLIENT_ID,
    client_name: FIRST_PARTY_CLIENT.clientName,
    app: app.product,
    app_name: app.name,
    app_home: app.home,
    redirect_uri: app.redirectUri,
    authorization_endpoint: `${AUTH_ORIGIN}/authorize`,
    token_endpoint: `${AUTH_ORIGIN}/oauth/token`,
    userinfo_endpoint: USERINFO_RESOURCE,
    resource: USERINFO_RESOURCE,
    scopes: [...app.scopes],
    allowed_email_domains: [...(app.allowedEmailDomains || [])],
    application_context: [...(app.contextScopes || [])],
    allowed_identity_providers: [...(app.identityProviders || ["google"])],
    configured_identity_providers: upstreamProviders(env)
      .filter((provider) => providerReadyForApp(provider, app))
      .map((provider) => ({
        id: provider.id,
        label: provider.label,
        callback: provider.callback,
        token_auth_method: provider.tokenAuthMethod || null,
        tenant_pinned: provider.id === "microsoft" ? provider.tenantPinned : undefined,
      })),
    pkce: "S256",
    client_model: "central-first-party-cimd",
    client_metadata_document: FIRST_PARTY_CLIENT_ID,
  };
}

function createAdminMcpServer(env) {
  const server = new McpServer({ name: "CodeFEDDY Identity Broker Admin", version: VERSION });

  server.registerTool("clintware_oauth_status", {
    title: "Get Clintware OAuth identity status",
    description: "Return safe OAuth/OIDC identity broker configuration and canonical endpoints. Never returns secrets.",
    inputSchema: {},
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  }, async () => ({
    content: [{ type: "text", text: JSON.stringify({
      ok: true,
      service: "CodeFEDDY Identity Broker",
      version: VERSION,
      configured: oauthConfigured(env),
      issuer: AUTH_ORIGIN,
      resource: USERINFO_RESOURCE,
      endpoints: {
        authorization: `${AUTH_ORIGIN}/authorize`,
        token: `${AUTH_ORIGIN}/oauth/token`,
        revocation: `${AUTH_ORIGIN}/oauth/token`,
        userinfo: USERINFO_RESOURCE,
        metadata: `${AUTH_ORIGIN}/.well-known/oauth-authorization-server`,
        protected_resource_metadata: `${AUTH_ORIGIN}/.well-known/oauth-protected-resource/userinfo`,
      },
      scopes: SUPPORTED_SCOPES,
      google_upstream: Boolean(googleClientId(env)),
      google_mode: "oidc-id-token-form-post",
      google_secret_required: false,
      upstream_identity_providers: upstreamProviders(env).map((provider) => ({
        id: provider.id,
        label: provider.label,
        configured: provider.configured,
        mode: provider.mode,
        callback: provider.callback,
        token_auth_method: provider.tokenAuthMethod || null,
        tenant_pinned: provider.id === "microsoft" ? provider.tenantPinned : undefined,
      })),
      storage: Boolean(env.OAUTH_KV),
      policy: "Upstream providers prove identity. Clintware binds that identity to the initiating application context and issues scoped rotating tokens; privileged Control Plane MCP remains separate.",
    }) }],
  }));

  server.registerTool("clintware_oauth_create_client", {
    title: "Register a Clintware service OAuth client",
    description: "Create a first-party OAuth client for a Clintware service. Server/BFF clients receive a secret once; browser clients are public and must use S256 PKCE.",
    inputSchema: {
      client_name: z.string().min(2).max(120),
      redirect_uris: z.array(z.string().url()).min(1).max(12),
      client_type: z.enum(["server", "browser"]).default("server"),
      client_uri: z.string().url().optional(),
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
  }, async ({ client_name, redirect_uris, client_type, client_uri }) => {
    if (!env.OAUTH_KV) return { isError: true, content: [{ type: "text", text: JSON.stringify({ error: "oauth_kv_not_configured" }) }] };
    const unique = [...new Set(redirect_uris.map((u) => u.trim()))];
    if (unique.some((u) => !validRedirectUri(u))) {
      return { isError: true, content: [{ type: "text", text: JSON.stringify({ error: "invalid_redirect_uri", rule: "HTTPS required except loopback localhost development URIs; fragments and embedded credentials are rejected." }) }] };
    }
    if (client_uri && !validRedirectUri(client_uri)) {
      return { isError: true, content: [{ type: "text", text: JSON.stringify({ error: "invalid_client_uri" }) }] };
    }
    const created = await oauthApi(env).createClient({
      clientName: client_name,
      redirectUris: unique,
      clientUri: client_uri,
      tokenEndpointAuthMethod: client_type === "browser" ? "none" : "client_secret_basic",
    });
    return { content: [{ type: "text", text: JSON.stringify({
      ok: true,
      client_id: created.clientId,
      client_secret: created.clientSecret || null,
      client_type,
      redirect_uris: created.redirectUris,
      token_endpoint_auth_method: created.tokenEndpointAuthMethod,
      scopes: SUPPORTED_SCOPES,
      authorization_endpoint: `${AUTH_ORIGIN}/authorize`,
      token_endpoint: `${AUTH_ORIGIN}/oauth/token`,
      userinfo_endpoint: USERINFO_RESOURCE,
      resource: USERINFO_RESOURCE,
      secret_warning: created.clientSecret ? "This client secret is returned once. Put it in the service's secret store; never ship it to browser code, logs, chat, or source control." : "Public client: no secret is issued. S256 PKCE is mandatory.",
    }) }] };
  });

  server.registerTool("clintware_oauth_list_clients", {
    title: "List Clintware OAuth clients",
    description: "List registered OAuth clients with secrets redacted.",
    inputSchema: { limit: z.number().int().min(1).max(100).default(50), cursor: z.string().optional() },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  }, async ({ limit, cursor }) => {
    if (!env.OAUTH_KV) return { isError: true, content: [{ type: "text", text: JSON.stringify({ error: "oauth_kv_not_configured" }) }] };
    const result = await oauthApi(env).listClients({ limit, cursor });
    return { content: [{ type: "text", text: JSON.stringify({ clients: (result.items || []).map(publicClient), cursor: result.cursor || null }) }] };
  });

  server.registerTool("clintware_oauth_delete_client", {
    title: "Delete and revoke a Clintware OAuth client",
    description: "Delete an OAuth client and cascade-revoke its grants/tokens. Requires the client ID to be repeated as confirmation.",
    inputSchema: { client_id: z.string().min(8), confirm_client_id: z.string().min(8) },
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
  }, async ({ client_id, confirm_client_id }) => {
    if (client_id !== confirm_client_id) return { isError: true, content: [{ type: "text", text: JSON.stringify({ error: "confirmation_mismatch" }) }] };
    await oauthApi(env).deleteClient(client_id);
    return { content: [{ type: "text", text: JSON.stringify({ ok: true, client_id, revoked: true }) }] };
  });

  return server;
}

async function handleAdminMcp(request, env, ctx) {
  const expected = String(env.CONTROL_PLANE_MCP_TOKEN || "");
  if (!expected || !(await secureEq(bearer(request), expected))) {
    return json({ error: "unauthorized" }, 401, { "www-authenticate": "Bearer" });
  }
  const handler = createMcpHandler(() => createAdminMcpServer(env), {
    route: "/admin-mcp",
    allowedHostnames: ["auth.codefeddy.com"],
    allowedOriginHostnames: ["chatgpt.com", "chat.openai.com", "platform.openai.com", "codefeddy.com", "www.codefeddy.com"],
    responseMode: "auto",
  });
  return handler(request, env, ctx);
}

const defaultHandler = {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/internal/google-access-token") {
      return internalGoogleAccessToken(request, env);
    }
    if (request.method === "GET" && url.pathname === "/delegated/google/start") {
      return beginDelegatedGoogle(request, env);
    }
    if (request.method === "GET" && url.pathname === "/delegated/google/status") {
      return delegatedGoogleStatus(env);
    }
    if (request.method === "GET" && url.pathname === "/callback" && url.searchParams.get("code")) {
      return finishDelegatedGoogle(request, env);
    }
    if (url.pathname === "/health") {
      return json({
        ok: true,
        service: "CodeFEDDY Identity Broker",
        version: VERSION,
        configured: oauthConfigured(env),
        google_configured: Boolean(googleClientId(env)),
        google_mode: "oidc-id-token-form-post",
        google_secret_required: false,
        google_client_id: googleClientId(env),
        upstream_identity_providers: upstreamProviders(env).map((provider) => ({
          id: provider.id,
          label: provider.label,
          configured: provider.configured,
          mode: provider.mode,
          callback: provider.callback,
          token_auth_method: provider.tokenAuthMethod || null,
          tenant_pinned: provider.id === "microsoft" ? provider.tenantPinned : undefined,
        })),
        oauth_storage: Boolean(env.OAUTH_KV),
        admin_mcp: Boolean(env.CONTROL_PLANE_MCP_TOKEN),
        first_party_client: FIRST_PARTY_CLIENT.clientName,
        first_party_client_id: FIRST_PARTY_CLIENT_ID,
        first_party_client_model: "cimd",
        first_party_apps: Object.keys(FIRST_PARTY_APPS),
        issuer: AUTH_ORIGIN,
        resource: USERINFO_RESOURCE,
        time: new Date().toISOString(),
      });
    }
    if (url.pathname === "/admin-mcp") return handleAdminMcp(request, env, ctx);
    if (request.method === "GET" && url.pathname === "/client/clintware-web") {
      return json(firstPartyClientMetadata(), 200, {
        "cache-control": "public, max-age=300",
      });
    }

    const firstPartyMatch = url.pathname.match(/^\/client-config\/([a-z0-9_-]+)$/);
    if (request.method === "GET" && firstPartyMatch) {
      const config = await firstPartyClientConfig(env, firstPartyMatch[1]);
      return config ? json(config) : json({ error: "unknown_first_party_app" }, 404);
    }
    if (url.pathname === "/authorize" && request.method === "GET") return beginConsent(request, env);
    if (url.pathname === "/authorize" && request.method === "POST") return finishConsent(request, env);
    if (url.pathname === "/callback" && request.method === "POST") return finishGoogle(request, env);
    const upstreamCallback = url.pathname.match(/^\/callback\/(microsoft|okta|auth0|pingone|oidc)$/);
    if (upstreamCallback && (request.method === "GET" || request.method === "POST")) {
      return finishEnterpriseOidc(request, env, upstreamCallback[1]);
    }
    if (url.pathname === "/") {
      return json({
        service: "CodeFEDDY Identity Broker",
        issuer: AUTH_ORIGIN,
        userinfo: USERINFO_RESOURCE,
        scopes: SUPPORTED_SCOPES,
        first_party_client: FIRST_PARTY_CLIENT.clientName,
        first_party_client_id: FIRST_PARTY_CLIENT_ID,
        first_party_client_model: "cimd",
        first_party_apps: Object.keys(FIRST_PARTY_APPS),
        upstream_identity_providers: upstreamProviders(env).map((provider) => ({
          id: provider.id,
          label: provider.label,
          configured: provider.configured,
          callback: provider.callback,
          token_auth_method: provider.tokenAuthMethod || null,
          tenant_pinned: provider.id === "microsoft" ? provider.tenantPinned : undefined,
        })),
        identity_boundary: "Upstream identity is always rebound to the initiating Clintware application context. Company-domain trust is never global.",
        docs: "Clintware first-party products share one central public OAuth Client ID Metadata Document with exact redirect allowlists. Applications opt in to upstream identity providers individually. External/service clients may still be managed through /admin-mcp.",
      });
    }
    return json({ error: "not_found" }, 404);
  },
};

const OAUTH_OPTIONS = {
  apiRoute: "/userinfo",
  apiHandler: userInfoHandler,
  defaultHandler,
  authorizeEndpoint: "/authorize",
  tokenEndpoint: "/oauth/token",
  scopesSupported: SUPPORTED_SCOPES,
  accessTokenTTL: 15 * 60,
  refreshTokenTTL: 30 * 24 * 60 * 60,
  resourceMetadata: {
    resource: USERINFO_RESOURCE,
    authorization_servers: [AUTH_ORIGIN],
    scopes_supported: SUPPORTED_SCOPES,
    resource_name: "Clintware Identity",
  },
  clientIdMetadataDocumentEnabled: true,
  allowImplicitFlow: false,
  allowPlainPKCE: false,
};

export const oauthProvider = new OAuthProvider(OAUTH_OPTIONS);
export default oauthProvider;

