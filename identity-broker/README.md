# CodeFEDDY Identity Broker

Central OAuth 2.1 / OIDC identity service for Clintware products at `https://auth.codefeddy.com`.

## Security model

- Upstream identity providers are **identity proof only**. Google uses signed OIDC ID-token form-post; enterprise providers use authorization-code + PKCE. Clintware validates issuer, audience, nonce/state, and the application/domain boundary before issuing its own token.
- Clintware does **not** request Google offline access and does **not** retain a Google refresh token for sign-in.
- Clintware issues its own short-lived access tokens and rotating refresh tokens through Cloudflare's `@cloudflare/workers-oauth-provider`.
- A stable pseudonymous Clintware user ID is derived from Google's immutable `sub`, so the same Google account maps back to the same Clintware identity without making email the primary key.
- OAuth authorization transactions are encrypted before their short-lived KV storage and bound to the same browser with a `Secure`, `HttpOnly`, `SameSite=Lax`, `__Host-` cookie.
- Public user authorization is isolated from the privileged `mcp.codefeddy.com` Control Plane. A Google login never grants repository, deployment, DNS, or administrative MCP permissions.
- Google is configured once for Clintware. First-party Clintware products share one central public OAuth client (`Clintware Web`) with exact per-product redirect allowlists and PKCE S256. Products do not create their own Google OAuth apps or carry Google client secrets.
- External/service OAuth clients can still be admin-created when needed. Open Dynamic Client Registration is intentionally not enabled.

## Federated upstream identity providers

The broker is provider-agnostic at the Clintware boundary. First-party applications explicitly opt in to upstream providers; successful authentication is then rebound to that application's own context before a Clintware token is issued.

Supported upstreams:

- Google — active canonical first-party provider.
- Microsoft Entra ID — OIDC authorization-code + PKCE with tenant-ID authorization for restricted enterprise applications.
- Okta — OIDC authorization-code + PKCE with exact issuer pinning.
- Auth0 — OIDC authorization-code + PKCE.
- PingOne — OIDC authorization-code + PKCE.
- Generic OIDC — covers standards-compliant providers such as Keycloak, JumpCloud, OneLogin, or another company SSO broker when configured.

The Neuron7 case application is allowed to use all configured upstreams, but identities from `@neuron7.ai` are still restricted to the `neuron7-case` application context. Clintware Mail and Control Plane Admin currently remain Google-only. This prevents a company-domain login from becoming a global Clintware identity grant.

Enterprise providers are **supported but not considered active until their issuer/client configuration exists**. The broker only renders buttons for providers that are both configured and allowlisted for the requesting application.

Provider callbacks:

- Google: `https://auth.codefeddy.com/callback`
- Microsoft: `https://auth.codefeddy.com/callback/microsoft`
- Okta: `https://auth.codefeddy.com/callback/okta`
- Auth0: `https://auth.codefeddy.com/callback/auth0`
- PingOne: `https://auth.codefeddy.com/callback/pingone`
- Generic OIDC: `https://auth.codefeddy.com/callback/oidc`

Optional deployment settings:

- `MICROSOFT_ENTRA_CLIENT_ID`
- `MICROSOFT_ENTRA_CLIENT_SECRET` when the Entra application is confidential
- `MICROSOFT_ENTRA_TENANT` (defaults to `organizations`; use a tenant GUID for domain-restricted applications)
- `MICROSOFT_ENTRA_TOKEN_AUTH_METHOD` (optional)
- `OKTA_OIDC_ISSUER`, `OKTA_OIDC_CLIENT_ID`, optional `OKTA_OIDC_CLIENT_SECRET`
- `OKTA_OIDC_TOKEN_AUTH_METHOD` (optional)
- `AUTH0_OIDC_ISSUER`, `AUTH0_OIDC_CLIENT_ID`, optional `AUTH0_OIDC_CLIENT_SECRET`
- `PINGONE_OIDC_ISSUER`, `PINGONE_OIDC_CLIENT_ID`, optional `PINGONE_OIDC_CLIENT_SECRET`
- `GENERIC_OIDC_ISSUER`, `GENERIC_OIDC_CLIENT_ID`, optional `GENERIC_OIDC_CLIENT_SECRET`

Do not reuse an upstream client registration for a callback that is not explicitly allowlisted at that provider.

### Microsoft Entra ID setup

Register a Microsoft Entra OIDC application with the exact callback `https://auth.codefeddy.com/callback/microsoft`. The broker uses authorization code + PKCE S256 and supports `client_secret_post`, `client_secret_basic`, or a public-client `none` token authentication mode.

For any Clintware application restricted to a company domain, set `MICROSOFT_ENTRA_TENANT` to that organization's immutable tenant GUID. Multitenant aliases (`organizations`, `common`, `consumers`) are not treated as a sufficient authorization boundary for a domain-restricted Clintware application. Microsoft email/UPN/username-shaped claims remain display/contact data; the restricted Microsoft path is authorized against the validated tenant ID.

Configuration:
- Secret: `MICROSOFT_ENTRA_CLIENT_ID`
- Secret when using a confidential client: `MICROSOFT_ENTRA_CLIENT_SECRET`
- Repository variable: `MICROSOFT_ENTRA_TENANT`
- Optional repository variable: `MICROSOFT_ENTRA_TOKEN_AUTH_METHOD` (`client_secret_post`, `client_secret_basic`, or `none`)

### Okta setup

Register an Okta OIDC application with the exact callback `https://auth.codefeddy.com/callback/okta`. Configure the exact HTTPS issuer for the intended Okta authorization server; discovery must return that same issuer and HTTPS authorization, token, and JWKS endpoints. The broker requests `openid email profile`, validates ID-token signature/audience/issuer/nonce, and requires an explicitly verified email claim before an email-domain restriction is used.

Configuration:
- Secret: `OKTA_OIDC_ISSUER`
- Secret: `OKTA_OIDC_CLIENT_ID`
- Secret when using a confidential client: `OKTA_OIDC_CLIENT_SECRET`
- Optional repository variable: `OKTA_OIDC_TOKEN_AUTH_METHOD` (`client_secret_basic`, `client_secret_post`, or `none`)

The deployment workflow preflights both providers when any of their settings are present, clears stale optional Worker configuration when settings are removed, and performs a live PKCE redirect smoke test for each provider that becomes active. Provider secrets are never returned by health, client-config, or admin-MCP surfaces.

## Public endpoints

- Authorization: `https://auth.codefeddy.com/authorize`
- Token: `https://auth.codefeddy.com/oauth/token`
- Revocation: advertised by OAuth metadata and handled by the provider at the token endpoint
- Protected user profile: `https://auth.codefeddy.com/userinfo`
- Authorization metadata: `https://auth.codefeddy.com/.well-known/oauth-authorization-server`
- Protected-resource metadata: RFC 9728 discovery for the `/userinfo` resource
- Health: `https://auth.codefeddy.com/health`

Scopes are `identity`, `email`, and `profile`. `identity` is required for login.

## Admin MCP

The identity broker exposes `https://auth.codefeddy.com/admin-mcp`, protected by the existing `CONTROL_PLANE_MCP_TOKEN`. It does not accept Google-user tokens.

Tools:

- `clintware_oauth_status`
- `clintware_oauth_create_client`
- `clintware_oauth_list_clients`
- `clintware_oauth_delete_client`

Use `client_type=server` for normal Clintware web apps with a backend/BFF. The generated client secret belongs only in that service's secret store. Use `client_type=browser` only when a backend is genuinely unavailable; it receives no secret and PKCE S256 is mandatory.

## Google setup

Create one Google Cloud **Web application** OAuth client for Clintware. This same Google client ID/secret is the canonical first-party Clintware Google identity and delegated-access client. Sign-in remains OIDC-only; Gmail/Calendar or other offline access uses a separate delegated refresh grant and never becomes an MCP credential.

Authorized redirect URIs:

- `https://auth.codefeddy.com/callback`
- `http://127.0.0.1:53682/` for the local Clintware delegated-access bootstrap helper

Repository/Actions secrets required for deployment:

- `GOOGLE_OAUTH_CLIENT_ID`
- `GOOGLE_OAUTH_CLIENT_SECRET`
- `GOOGLE_DELEGATED_REFRESH_TOKEN` when a Clintware service needs approved offline Google API access such as Gmail/Calendar
- `CONTROL_PLANE_MCP_TOKEN` (already used by CodeFEDDY Control Plane)
- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ACCOUNT_ID`

The deployment workflow creates/reuses a Workers KV namespace named `clintware-identity-oauth` and injects it as `OAUTH_KV`. The Cloudflare API token therefore needs **Workers Scripts** deployment rights, the normal custom-domain permissions, and **Workers KV Storage Write**.

## First-party Clintware products

First-party products use the central `Clintware Web` public client. They do **not** register separate OAuth clients.

Current product config endpoints:

- `GET /client-config/mail`
- `GET /client-config/neuron7-case`

Both return the same central Clintware client ID and authorization/token/userinfo endpoints, but each receives its own exact allowlisted redirect URI. The client ID is the deterministic Client ID Metadata Document URL `https://auth.codefeddy.com/client/clintware-web`. PKCE S256 is mandatory and there is no product-level client secret or per-product OAuth registration.

To add another first-party product, add its exact HTTPS callback to `src/first-party.js`. The metadata document changes with that allowlist; no new OAuth client record is created.

External integrations that should not share the first-party Clintware trust boundary may still be registered through the authenticated `/admin-mcp` tools.

## Session permanence

"Permanent" means the user account identity remains stable, not that bearer credentials never expire. Access tokens are 15 minutes. Rotating refresh grants are 30 days. When a grant eventually expires or is revoked, signing in with the same Google account produces the same stable Clintware `sub` and reconnects the user's existing service account.

## Local validation

The committed `wrangler.jsonc` intentionally does not contain a KV namespace ID. Generate a deploy/dev config with:

```sh
node scripts/render-wrangler.mjs <32-char-kv-namespace-id>
npm run check
npx wrangler deploy --dry-run --config wrangler.generated.jsonc
```

Never commit `wrangler.generated.jsonc`, `.dev.vars`, Google credentials, OAuth client secrets, access tokens, or refresh tokens.

