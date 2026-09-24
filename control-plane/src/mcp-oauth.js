import { OAuthProvider, AuthorizationError } from "@cloudflare/workers-oauth-provider";
import { WorkerEntrypoint } from "cloudflare:workers";
import { isControlPlaneAdminIdentity } from "./admin.js";
import { handleMcpWithAuth } from "./index.js";

const MCP_RESOURCE = "https://mcp.codefeddy.com/mcp";
const MCP_ISSUER = "https://mcp.codefeddy.com";
const AUTH_CONFIG_URL = "https://auth.codefeddy.com/client-config/control-plane-mcp";
const MCP_SCOPES = ["clintware:read", "clintware:write", "local:run"];
const TX_COOKIE = "__Host-clintware-mcp-oauth";
const TX_TTL_SECONDS = 600;

const te = new TextEncoder();
const td = new TextDecoder();

function b64u(bytes) {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function unb64(value) {
  const n = String(value || "").replace(/-/g, "+").replace(/_/g, "/");
  const p = n + "=".repeat((4 - (n.length % 4)) % 4);
  const s = atob(p);
  return Uint8Array.from(s, (c) => c.charCodeAt(0));
}

function randomToken(bytes = 32) {
  const value = new Uint8Array(bytes);
  crypto.getRandomValues(value);
  return b64u(value);
}

async function digest(value) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", te.encode(String(value || ""))));
}

async function transactionKey(env) {
  const secret = String(env.CONTROL_PLANE_ADMIN_TOKEN || env.CONTROL_PLANE_MCP_TOKEN || "");
  if (!secret) throw new Error("mcp_oauth_transaction_key_not_configured");
  const raw = await crypto.subtle.digest("SHA-256", te.encode("clintware-mcp-oauth-v1\\0" + secret));
  return crypto.subtle.importKey("raw", raw, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}

async function seal(env, value) {
  const iv = new Uint8Array(12);
  crypto.getRandomValues(iv);
  const key = await transactionKey(env);
  const clear = te.encode(JSON.stringify(value));
  const cipher = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: te.encode("clintware-mcp-oauth-tx") },
    key,
    clear,
  );
  return b64u(iv) + "." + b64u(new Uint8Array(cipher));
}

async function open(env, value) {
  const parts = String(value || "").split(".");
  if (parts.length !== 2) return null;
  try {
    const key = await transactionKey(env);
    const clear = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: unb64(parts[0]), additionalData: te.encode("clintware-mcp-oauth-tx") },
      key,
      unb64(parts[1]),
    );
    return JSON.parse(td.decode(clear));
  } catch {
    return null;
  }
}

function cookie(request, name) {
  const raw = request.headers.get("cookie") || "";
  for (const part of raw.split(";")) {
    const idx = part.indexOf("=");
    if (idx > 0 && part.slice(0, idx).trim() === name) {
      return decodeURIComponent(part.slice(idx + 1).trim());
    }
  }
  return "";
}

function setCookie(value) {
  return TX_COOKIE + "=" + encodeURIComponent(value) + "; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=" + TX_TTL_SECONDS;
}

function clearCookie() {
  return TX_COOKIE + "=; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=0";
}

function json(value, status = 200, extra = {}) {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      ...extra,
    },
  });
}

async function upstreamConfig() {
  const response = await fetch(AUTH_CONFIG_URL, {
    headers: { accept: "application/json" },
    cf: { cacheTtl: 300, cacheEverything: true },
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok || !data.client_id || !data.authorization_endpoint || !data.token_endpoint || !data.userinfo_endpoint || !data.redirect_uri) {
    throw new Error("clintware_identity_config_unavailable");
  }
  return data;
}

function redirectAuthorizationError(error) {
  if (!(error instanceof AuthorizationError)) throw error;
  if (!error.redirectUri) {
    return json({ error: error.code || "invalid_request", error_description: error.description || "Invalid OAuth request." }, 400);
  }
  const redirect = new URL(error.redirectUri);
  redirect.searchParams.set("error", error.code || "invalid_request");
  redirect.searchParams.set("error_description", error.description || "Invalid OAuth request.");
  if (error.state) redirect.searchParams.set("state", error.state);
  if (error.issuer) redirect.searchParams.set("iss", error.issuer);
  return Response.redirect(redirect, 302);
}

async function beginAuthorization(request, env) {
  let oauthRequest;
  try {
    oauthRequest = await env.OAUTH_PROVIDER.parseAuthRequest(request);
  } catch (error) {
    return redirectAuthorizationError(error);
  }

  const client = await env.OAUTH_PROVIDER.lookupClient(oauthRequest.clientId);
  if (!client) return json({ error: "unknown_oauth_client" }, 400);

  const upstream = await upstreamConfig();
  const binding = randomToken(32);
  const verifier = randomToken(48);
  const challenge = b64u(await digest(verifier));
  const transaction = await seal(env, {
    kind: "chatgpt-mcp",
    oauthRequest,
    verifier,
    bindingHash: b64u(await digest(binding)),
    createdAt: Date.now(),
  });

  const authorize = new URL(upstream.authorization_endpoint);
  authorize.searchParams.set("response_type", "code");
  authorize.searchParams.set("client_id", upstream.client_id);
  authorize.searchParams.set("redirect_uri", upstream.redirect_uri);
  authorize.searchParams.set("scope", (upstream.scopes || ["identity", "email", "profile"]).join(" "));
  authorize.searchParams.set("state", transaction);
  authorize.searchParams.set("code_challenge", challenge);
  authorize.searchParams.set("code_challenge_method", "S256");
  authorize.searchParams.set("resource", upstream.resource);

  const headers = new Headers({
    location: authorize.toString(),
    "cache-control": "no-store",
    "referrer-policy": "no-referrer",
  });
  headers.append("set-cookie", setCookie(binding));
  return new Response(null, { status: 302, headers });
}

async function finishAuthorization(request, env) {
  const url = new URL(request.url);
  const code = String(url.searchParams.get("code") || "");
  const state = String(url.searchParams.get("state") || "");
  const upstreamError = String(url.searchParams.get("error") || "");

  if (upstreamError) {
    return json({
      error: "identity_authorization_failed",
      upstream_error: upstreamError,
      description: String(url.searchParams.get("error_description") || ""),
    }, 400, { "set-cookie": clearCookie() });
  }

  if (!code || !state) return json({ error: "missing_identity_authorization_response" }, 400, { "set-cookie": clearCookie() });

  const transaction = await open(env, state);
  const age = transaction ? Date.now() - Number(transaction.createdAt || 0) : Infinity;
  if (!transaction || transaction.kind !== "chatgpt-mcp" || !Number.isFinite(age) || age < 0 || age > TX_TTL_SECONDS * 1000) {
    return json({ error: "authorization_transaction_expired" }, 400, { "set-cookie": clearCookie() });
  }

  const binding = cookie(request, TX_COOKIE);
  if (!binding || b64u(await digest(binding)) !== transaction.bindingHash) {
    return json({ error: "authorization_transaction_mismatch" }, 400, { "set-cookie": clearCookie() });
  }

  const upstream = await upstreamConfig();
  const tokenResponse = await fetch(upstream.token_endpoint, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      client_id: upstream.client_id,
      code,
      redirect_uri: upstream.redirect_uri,
      code_verifier: transaction.verifier,
      resource: upstream.resource,
    }),
  });
  const token = await tokenResponse.json().catch(() => ({}));
  if (!tokenResponse.ok || !token.access_token) {
    return json({ error: "identity_token_exchange_failed" }, 502, { "set-cookie": clearCookie() });
  }

  const profileResponse = await fetch(upstream.userinfo_endpoint, {
    headers: { authorization: "Bearer " + token.access_token, accept: "application/json" },
  });
  const profile = await profileResponse.json().catch(() => ({}));
  if (!profileResponse.ok || !isControlPlaneAdminIdentity(env, profile)) {
    return json({ error: "control_plane_owner_required" }, 403, { "set-cookie": clearCookie() });
  }

  const grantedScopes = transaction.oauthRequest.scope.filter((scope) => MCP_SCOPES.includes(scope));
  const authResult = await env.OAUTH_PROVIDER.completeAuthorization({
    request: transaction.oauthRequest,
    userId: String(profile.sub || profile.email),
    metadata: {
      source: "clintware-identity",
      connection: "chatgpt-mcp",
    },
    scope: grantedScopes,
    props: {
      sub: String(profile.sub || ""),
      email: String(profile.email || ""),
      name: String(profile.name || profile.email || "Clintware owner"),
      scopes: grantedScopes,
      allowed_products: ["*"],
      connection: "chatgpt-oauth",
    },
  });

  const headers = new Headers({
    location: authResult.redirectTo,
    "cache-control": "no-store",
  });
  headers.append("set-cookie", clearCookie());
  return new Response(null, { status: 302, headers });
}

const defaultHandler = {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/oauth/authorize") return beginAuthorization(request, env);
    if (url.pathname === "/oauth/callback") return finishAuthorization(request, env);
    return json({ error: "not_found" }, 404);
  },
};

export class McpOAuthApiHandler extends WorkerEntrypoint {
  async fetch(request) {
    const props = this.ctx.props || {};
    if (!props.sub || !Array.isArray(props.allowed_products)) {
      return json({ error: "oauth_identity_missing" }, 403);
    }
    const auth = {
      ok: true,
      root: false,
      client_id: "oauth:" + props.sub,
      name: props.name || "Clintware OAuth client",
      allowed_products: props.allowed_products,
      oauth: true,
      scopes: props.scopes || [],
    };
    return handleMcpWithAuth(request, this.env, this.ctx, auth);
  }
}

export const mcpOAuthProvider = new OAuthProvider({
  apiRoute: "/mcp",
  apiHandler: McpOAuthApiHandler,
  defaultHandler,
  authorizeEndpoint: "/oauth/authorize",
  tokenEndpoint: "/oauth/token",
  scopesSupported: MCP_SCOPES,
  accessTokenTTL: 15 * 60,
  refreshTokenTTL: 30 * 24 * 60 * 60,
  resourceMetadata: {
    resource: MCP_RESOURCE,
    authorization_servers: [MCP_ISSUER],
    scopes_supported: MCP_SCOPES,
    bearer_methods_supported: ["header"],
    resource_name: "Clintware MCP Control Plane",
    resource_documentation: "https://mcp.codefeddy.com/",
  },
  clientIdMetadataDocumentEnabled: true,
  allowImplicitFlow: false,
  allowPlainPKCE: false,
});

export function isMcpOAuthRoute(url) {
  const path = typeof url === "string" ? new URL(url).pathname : url.pathname;
  return path === "/mcp"
    || path === "/oauth/authorize"
    || path === "/oauth/callback"
    || path === "/oauth/token"
    || path === "/.well-known/oauth-authorization-server"
    || path === "/.well-known/oauth-protected-resource/mcp";
}

