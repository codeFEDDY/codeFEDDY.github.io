import { createRemoteJWKSet, jwtVerify } from "jose";

const GOOGLE_CLIENT_ID = "378690450945-nnb0d9st2d9s5lj2alt7q1hdm3pfige7.apps.googleusercontent.com";
const GOOGLE_CALLBACK = "https://auth.codefeddy.com/callback";
const GOOGLE_AUTH = "https://accounts.google.com/o/oauth2/v2/auth";
const GOOGLE_TOKEN = "https://oauth2.googleapis.com/token";
const GOOGLE_JWKS = "https://www.googleapis.com/oauth2/v3/certs";
const GRANT_KEY = "delegated:google:primary";
const BIND_COOKIE = "__Host-clintware-google-delegated";
const STATE_TTL_MS = 10 * 60 * 1000;
const SCOPES = [
  "openid",
  "email",
  "profile",
  "https://www.googleapis.com/auth/gmail.send",
  "https://www.googleapis.com/auth/calendar.events",
  "https://www.googleapis.com/auth/calendar.freebusy",
];

const te = new TextEncoder();
const td = new TextDecoder();

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

function base64url(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function fromBase64url(value) {
  const normalized = String(value || "").replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - normalized.length % 4) % 4);
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

async function secureEq(a, b) {
  if (!a || !b) return false;
  const [x, y] = await Promise.all([sha256(a), sha256(b)]);
  return x === y;
}

async function cryptoKey(env, purpose) {
  const secret = String(env.CONTROL_PLANE_MCP_TOKEN || env.OAUTH_STATE_SECRET || "");
  if (!secret) throw new Error("delegated_crypto_secret_missing");
  const raw = await crypto.subtle.digest(
    "SHA-256",
    te.encode(`clintware-google-delegated:\0${purpose}:\0${secret}`),
  );
  return crypto.subtle.importKey("raw", raw, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}

async function seal(env, value, purpose) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const key = await cryptoKey(env, purpose);
  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: te.encode(`clintware-google-delegated:${purpose}:v1`) },
    key,
    te.encode(JSON.stringify(value)),
  );
  return `${base64url(iv)}.${base64url(new Uint8Array(ciphertext))}`;
}

async function unseal(env, value, purpose) {
  const [ivPart, cipherPart] = String(value || "").split(".");
  if (!ivPart || !cipherPart) throw new Error("invalid_delegated_envelope");
  const key = await cryptoKey(env, purpose);
  const clear = await crypto.subtle.decrypt(
    {
      name: "AES-GCM",
      iv: fromBase64url(ivPart),
      additionalData: te.encode(`clintware-google-delegated:${purpose}:v1`),
    },
    key,
    fromBase64url(cipherPart),
  );
  return JSON.parse(td.decode(clear));
}

function cookieValue(request, name) {
  const raw = request.headers.get("cookie") || "";
  for (const part of raw.split(";")) {
    const i = part.indexOf("=");
    if (i > 0 && part.slice(0, i).trim() === name) return decodeURIComponent(part.slice(i + 1).trim());
  }
  return "";
}

function setCookie(value) {
  return `${BIND_COOKIE}=${encodeURIComponent(value)}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=600`;
}

function clearCookie() {
  return `${BIND_COOKIE}=; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=0`;
}

function allowedEmails(env) {
  return String(env.GOOGLE_DELEGATED_ALLOWED_EMAILS || "clint.kosh@gmail.com")
    .split(",")
    .map((x) => x.trim().toLowerCase())
    .filter(Boolean);
}

async function codeChallenge(verifier) {
  const digest = await crypto.subtle.digest("SHA-256", te.encode(verifier));
  return base64url(new Uint8Array(digest));
}

export async function beginDelegatedGoogle(request, env) {
  if (!env.OAUTH_KV || !env.GOOGLE_OAUTH_CLIENT_SECRET) {
    return json({ error: "google_delegated_not_configured" }, 503);
  }

  const binding = randomToken(32);
  const verifier = randomToken(48);
  const nonce = randomToken(24);
  const state = await seal(env, {
    kind: "google_delegated",
    createdAt: Date.now(),
    bindingHash: await sha256(binding),
    verifier,
    nonce,
  }, "state");

  const auth = new URL(GOOGLE_AUTH);
  auth.searchParams.set("client_id", GOOGLE_CLIENT_ID);
  auth.searchParams.set("redirect_uri", GOOGLE_CALLBACK);
  auth.searchParams.set("response_type", "code");
  auth.searchParams.set("scope", SCOPES.join(" "));
  auth.searchParams.set("access_type", "offline");
  auth.searchParams.set("prompt", "consent");
  auth.searchParams.set("include_granted_scopes", "true");
  auth.searchParams.set("state", state);
  auth.searchParams.set("nonce", nonce);
  auth.searchParams.set("code_challenge", await codeChallenge(verifier));
  auth.searchParams.set("code_challenge_method", "S256");

  return new Response(null, {
    status: 302,
    headers: {
      location: auth.toString(),
      "set-cookie": setCookie(binding),
      "cache-control": "no-store",
    },
  });
}

export async function finishDelegatedGoogle(request, env) {
  const url = new URL(request.url);
  const code = url.searchParams.get("code") || "";
  const stateRaw = url.searchParams.get("state") || "";
  const upstreamError = url.searchParams.get("error") || "";
  if (upstreamError) {
    return json({ error: "google_delegated_authorization_failed", google_error: upstreamError }, 400, {
      "set-cookie": clearCookie(),
    });
  }
  if (!code || !stateRaw) return json({ error: "missing_google_delegated_response" }, 400, { "set-cookie": clearCookie() });

  let state;
  try {
    state = await unseal(env, stateRaw, "state");
  } catch {
    return json({ error: "invalid_google_delegated_state" }, 400, { "set-cookie": clearCookie() });
  }
  const age = Date.now() - Number(state.createdAt || 0);
  const binding = cookieValue(request, BIND_COOKIE);
  if (
    state.kind !== "google_delegated" ||
    !Number.isFinite(age) ||
    age < 0 ||
    age > STATE_TTL_MS ||
    !binding ||
    !(await secureEq(await sha256(binding), state.bindingHash))
  ) {
    return json({ error: "google_delegated_state_expired" }, 400, { "set-cookie": clearCookie() });
  }

  const tokenResponse = await fetch(GOOGLE_TOKEN, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      client_id: GOOGLE_CLIENT_ID,
      client_secret: env.GOOGLE_OAUTH_CLIENT_SECRET,
      redirect_uri: GOOGLE_CALLBACK,
      grant_type: "authorization_code",
      code_verifier: state.verifier,
    }),
  });
  const tokens = await tokenResponse.json().catch(() => ({}));
  if (!tokenResponse.ok || !tokens.refresh_token || !tokens.id_token) {
    return json({
      error: "google_delegated_token_exchange_failed",
      status: tokenResponse.status,
      refresh_token_received: Boolean(tokens.refresh_token),
    }, 502, { "set-cookie": clearCookie() });
  }

  const jwks = createRemoteJWKSet(new URL(GOOGLE_JWKS));
  const verified = await jwtVerify(tokens.id_token, jwks, {
    issuer: ["https://accounts.google.com", "accounts.google.com"],
    audience: GOOGLE_CLIENT_ID,
    clockTolerance: 10,
  });
  const claims = verified.payload;
  if (claims.nonce !== state.nonce) {
    return json({ error: "google_delegated_nonce_mismatch" }, 400, { "set-cookie": clearCookie() });
  }
  const email = String(claims.email || "").toLowerCase();
  if (!email || !allowedEmails(env).includes(email) || !(claims.email_verified === true || claims.email_verified === "true")) {
    return json({ error: "google_delegated_account_not_allowed" }, 403, { "set-cookie": clearCookie() });
  }

  const grant = await seal(env, {
    refreshToken: tokens.refresh_token,
    email,
    subject: String(claims.sub || ""),
    scope: String(tokens.scope || SCOPES.join(" ")),
    createdAt: Date.now(),
  }, "grant");
  await env.OAUTH_KV.put(GRANT_KEY, grant);

  return new Response(null, {
    status: 302,
    headers: {
      location: "https://meet.codefeddy.com/?calendar=connected",
      "set-cookie": clearCookie(),
      "cache-control": "no-store",
    },
  });
}

async function loadGrant(env) {
  if (!env.OAUTH_KV) return null;
  const sealed = await env.OAUTH_KV.get(GRANT_KEY);
  if (!sealed) return null;
  try {
    return await unseal(env, sealed, "grant");
  } catch {
    return null;
  }
}

export async function delegatedGoogleStatus(env) {
  const grant = await loadGrant(env);
  return json({ connected: Boolean(grant), scopes: grant ? SCOPES.filter((x) => !["openid", "email", "profile"].includes(x)) : [] });
}

export async function internalGoogleAccessToken(request, env) {
  const expected = String(env.GOOGLE_DELEGATED_BRIDGE_SECRET || "");
  const supplied = request.headers.get("x-clintware-google-secret") || "";
  if (!expected || !(await secureEq(expected, supplied))) return json({ error: "unauthorized" }, 401);
  if (!env.GOOGLE_OAUTH_CLIENT_SECRET) return json({ error: "google_client_secret_missing" }, 503);

  const grant = await loadGrant(env);
  if (!grant?.refreshToken) return json({ error: "google_delegated_grant_missing" }, 404);

  const response = await fetch(GOOGLE_TOKEN, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: GOOGLE_CLIENT_ID,
      client_secret: env.GOOGLE_OAUTH_CLIENT_SECRET,
      refresh_token: grant.refreshToken,
      grant_type: "refresh_token",
    }),
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok || !data.access_token) {
    return json({ error: "google_delegated_refresh_failed", status: response.status }, 502);
  }
  return json({
    access_token: data.access_token,
    token_type: data.token_type || "Bearer",
    expires_in: Number(data.expires_in || 3600),
    scope: data.scope || grant.scope || "",
  });
}

