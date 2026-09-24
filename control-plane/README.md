# CodeFEDDY Control Plane

Reusable, least-privilege access and telemetry layer for Clintware products and external AI systems.

ProofOS is the first registered production consumer. The control plane keeps GitHub, Cloudflare, deployment, analytics, and product credentials centralized inside Clintware instead of distributing broad credentials to every external system.


## Convenience and access rule

Clintware should prefer the Control Plane/MCP whenever it reduces repeated setup, lets multiple authorized clients reuse the same capability, or avoids distributing provider credentials.

Default order of operations:

1. **MCP/control-plane capability first** when the action can be safely mediated server-side.
2. **One-line PowerShell bootstrap second** when an operation must happen on a local Windows machine or requires an interactive local browser/device step.
3. **Manual console work last**, only when the provider exposes no safe programmable path.

Access is spread by capability, not by secret:

- GitHub, Cloudflare, Google, research, deployment, and other provider credentials remain centralized server-side whenever possible.
- ChatGPT, Gemini, Claude, Perplexity, local Clintware tools, and future clients receive separate revocable Clintware MCP credentials with only the products/capabilities they need.
- A client may invoke an approved Google/GitHub/Cloudflare action through Clintware without receiving the underlying provider token.
- Local bootstrap scripts should call Clintware MCP/control-plane endpoints where doing so removes duplicated credentials or setup.
- Scripts must be idempotent, fail-fast, self-verifying, and maintained in this repository so the user can normally run a short `irm ... | iex` launcher instead of pasting large transient scripts.
- Provider credentials must never be copied into public source, workflow JSON, prompts, logs, or unrelated client configuration.
- Brand/security boundaries remain intact: sharing a Clintware capability does not authorize unrelated products or identities to inherit the underlying credential.

This is the default implementation pattern for new Clintware automation unless a provider limitation or security boundary requires a different design.

## Architecture

`external AI/app -> mcp.codefeddy.com -> identity -> client product scope -> policy -> Clintware Flow / capability -> action -> audit`

The MCP endpoint is one interface into the broader control plane. The same Worker also exposes authenticated application/event APIs.

## Admin operations dashboard

The authenticated operations console is available at `https://mcp.codefeddy.com/admin`.

- Sign-in uses the shared Clintware Identity authority at `auth.codefeddy.com`; no separate Google OAuth application is created.
- By default, verified `@codefeddy.com` identities may enter the console. Set `CONTROL_PLANE_ADMIN_EMAILS` to a comma-separated allowlist to restrict this further.
- The dashboard shows measured Control Plane telemetry, registered products, MCP clients/tools, adapters, Quillgeist Lite runner status, active site probes, observed latency, and 1/7/30/90-day trends.
- A 15-minute Cron Trigger stores bounded 90-day health snapshots so observed uptime and service trends accumulate even when the dashboard is not open.
- Provider quota/billing utilization is not fabricated. The panel displays only metrics available from Clintware telemetry and active probes; provider-specific quota sources can be added as optional adapters later.
- Browser sessions are encrypted, host-bound, HttpOnly, Secure, SameSite=Lax cookies. Google user tokens are not infrastructure credentials and do not grant MCP provider authority.

## Primary endpoints

- `GET /health` — safe health/configuration status
- `POST /mcp` — authenticated MCP endpoint
- `GET /api/v1` — API index
- `POST /api/v1/events` — canonical product event ingestion
- `POST /api/v1/research` — research gateway (`research.invoke` capability). Provider chain: Exa search + Cloudflare Workers AI synthesis (primary), Exa answer (fallback), 24h result cache. Credentials: `EXA_API_KEY` worker secret (preferred) or Control Plane durable storage set via the `clintware_research_configure` MCP tool. Without a key the gateway answers `available:false` (`research_provider_not_configured`) and products degrade gracefully. Product workers authenticate via account service bindings (caller identity) or product tokens.
- `GET /api/v1/products/:product/summary`
- `GET /api/v1/products/:product/recent`
- `GET /api/v1/products/:product/errors`
- `GET /api/v1/products/:product/daily`
- `GET /api/v1/products/:product/funnel`
- `GET /api/v1/products/:product/providers`
- `GET /api/v1/products/:product/cache`
- `GET /api/v1/products/:product/conversions`
- `POST /api/v1/repo/read`
- `POST /api/v1/repo/branch`
- `POST /api/v1/repo/write`
- `POST /api/v1/deploy`
- `POST /api/v1/dns/ensure`

## MCP tools

Read/analytics:

- `clintware_control_plane_status`
- `clintware_product_manifest`
- `clintware_capability_check`
- `clintware_usage_summary`
- `clintware_feature_funnel`
- `clintware_provider_breakdown`
- `clintware_cache_performance`
- `clintware_conversion_summary`
- `clintware_recent_errors`
- `clintware_recent_activity`
- `clintware_daily_activity`
- `clintware_repo_read_file`

Scoped mutations:

- `clintware_repo_create_branch`
- `clintware_repo_write_file`
- `clintware_deploy_workflow`
- `clintware_dns_ensure_record`

Private orchestration:

- `clintware_flow_list`
- `clintware_flow_get`
- `clintware_flow_put`
- `clintware_flow_run`
- `clintware_flow_runs`

Flow definitions live inside the Control Plane and contain credential references only. See `CLINTWARE_FLOW.md`.

Mutation tools enforce each product's manifest before touching external infrastructure.

## ProofOS scope

The default ProofOS manifest permits:

- reading `codeFEDDY/codeFEDDY.github.io`
- writing only `proofos/`, `control-plane/`, and `public/proofos/`
- branch creation
- dispatching only the ProofOS/control-plane deployment workflows
- ensuring only allowlisted Clintware DNS names
- ProofOS telemetry read/write

It explicitly denies secret reads, billing administration, repository deletion, unrelated repository writes, and broad infrastructure administration.

## Required Worker secrets

Provision these once in Cloudflare. External AI systems receive only the scoped Control Plane MCP credential, never the underlying credentials.

- `CONTROL_PLANE_MCP_TOKEN` — bearer credential used by trusted MCP clients such as the Perplexity ProofOS project
- `CONTROL_PLANE_ADMIN_TOKEN` — administrative API credential used to register products/clients; preferred as a separate credential. If it is not configured, the root `CONTROL_PLANE_MCP_TOKEN` can perform administrative REST actions so scoped client keys can still be provisioned. Once the separate admin token exists, it takes precedence
- `GITHUB_CONTROL_PLANE_TOKEN` — central GitHub credential with only the repository permissions needed for scoped writes/branch/workflow actions
- `CLOUDFLARE_CONTROL_PLANE_TOKEN` — Cloudflare token limited to required DNS operations
- `CLOUDFLARE_ZONE_ID` — Clintware zone ID

`GITHUB_CONTROL_PLANE_TOKEN` and the Cloudflare token are never returned through the API or MCP. The legacy `GITHUB_CONTROL_PLANE_TOKEN` remains a backward-compatible fallback for the `clintkosh` identity. New account-specific credentials use `GITHUB_TOKEN_<IDENTITY>`.

## Create a ProofOS application token

After deployment, an administrator can create the ProofOS application token once:

```bash
curl -X POST https://mcp.codefeddy.com/api/v1/products/client \
  -H "Authorization: Bearer $CONTROL_PLANE_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"product":"proofos"}'
```

Store the returned token as `CLINTWARE_PRODUCT_TOKEN` in the ProofOS server runtime. Only its SHA-256 hash is retained by the Control Plane.

The ProofOS application must never expose this token to browser JavaScript. Browser actions should reach ProofOS server routes, which emit telemetry server-side through `proofos/lib/control-plane.js`.

## Canonical event model

Events support:

- `event_id`
- `timestamp` / `ts`
- `product`
- `environment`
- `anonymous_session_id`
- `request_id`
- `feature`
- `action`
- `route`
- `provider`
- `model`
- `cache_status`
- `research_freshness`
- `tool_calls`
- `source_count`
- `first_party_source_count`
- `contradiction_count`
- `evidence_nodes_considered`
- `evidence_nodes_used`
- `latency_ms`
- `input_size`
- `output_size`
- `reported_api_cost`
- `estimated_cost_avoided`
- `fallback_used`
- `success`
- `error_class`
- `conversion_event`
- safe `metadata`

Raw visitor prompts/responses are intentionally not required for product analytics.

## Jira adapter

Jira Cloud access is mediated by Atlassian OAuth 2.0 (3LO). qq can launch the one-time browser authorization with the allowlisted `connect-jira` task; Jira access/refresh tokens remain encrypted server-side. MCP clients use scoped `clintware_jira_*` tools and never receive the provider credential.

See `JIRA-SETUP.md` for callback URL, scopes, secret names, connection flow, and tool list.

## Deployment

The Worker is configured for `mcp.codefeddy.com`. Use `.github/workflows/deploy-control-plane.yml` or run from this directory:

```bash
npm install
npm run check
npx wrangler deploy --dry-run
npm run deploy
```

The deployment workflow uses the repository's existing `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` GitHub secrets.


## Multiple GitHub identities

The Control Plane now resolves GitHub credentials from each product manifest instead of assuming one global GitHub account.

A manifest may set:

```json
{
  "repo": {
    "identity": "codefeddy",
    "owner": "codeFEDDY",
    "name": "codeFEDDY.github.io"
  }
}
```

The identity is normalized and mapped to a Cloudflare Worker secret:

- `clintkosh` -> `GITHUB_TOKEN_CLINTKOSH`
- `codefeddy` -> `GITHUB_TOKEN_CODEFEDDY`
- `Acme Labs` -> `GITHUB_TOKEN_ACME_LABS`

This lets one `mcp.codefeddy.com` client work across independent GitHub accounts without receiving or switching provider credentials. Each product still has its own repository/path/workflow policy.

Use `control-plane/add-github-identity.ps1` to add another GitHub account once. Unknown account secrets are not deleted by normal deployments. `GET /health` reports identity aliases, repository mappings, expected secret names, and whether each identity is configured; it never returns token values.

CodeFEDDY is registered as its own product and resolves to `codeFEDDY/codeFEDDY.github.io` using the `codefeddy` identity. Clintware products continue to resolve to the `clintkosh` identity.


## Cross-LLM routing

The Control Plane exposes a vendor-neutral handshake and compact work-handoff protocol so different LLM clients can continue the same Clintware project without sharing underlying provider credentials.

MCP tools:

- `clintware_client_handshake`
- `clintware_handoff_put`
- `clintware_handoff_get`

Authenticated REST equivalents:

- `POST /api/v1/handoffs`
- `GET /api/v1/handoffs/:id`

See `UNIVERSAL-LLM-ROUTING.md` for the reusable prompt and packet schema.


## ChatGPT OAuth connection

The production MCP endpoint is `https://mcp.codefeddy.com/mcp`.

ChatGPT/custom OpenAI MCP clients should use the OAuth 2.1 discovery flow exposed by the Control Plane rather than receiving `CONTROL_PLANE_MCP_TOKEN` or a GitHub credential directly.

- Protected resource metadata: `https://mcp.codefeddy.com/.well-known/oauth-protected-resource/mcp`
- Authorization server metadata: `https://mcp.codefeddy.com/.well-known/oauth-authorization-server`
- Authorization endpoint: `https://mcp.codefeddy.com/oauth/authorize`
- Token endpoint: `https://mcp.codefeddy.com/oauth/token`
- Upstream owner identity: `auth.codefeddy.com` via the dedicated `control-plane-mcp` first-party callback
- PKCE: S256
- ChatGPT client identification: CIMD
- Provider credentials: remain server-side behind the Control Plane

Existing root/per-client bearer credentials remain supported for current non-OAuth consumers. OAuth is an additional front door; it does not replace or rotate existing MCP, GitHub, Cloudflare, Jira, Confluence, or product credentials.

The intended default route for ChatGPT is:

```text
ChatGPT -> mcp.codefeddy.com/mcp -> scoped Control Plane tools -> qq when local Windows execution is required
```

Do not fall back to direct GitHub writes merely to trigger qq when the Clintware MCP connection is available.

## Per-client MCP credentials

External LLMs do not need to share the root `CONTROL_PLANE_MCP_TOKEN`. The Control Plane can issue a separate revocable credential for each client while retaining only its SHA-256 hash.

Administrative endpoints:

- `GET /api/v1/mcp/clients` — list client metadata; never returns token hashes or plaintext tokens
- `POST /api/v1/mcp/clients` — create/rotate a named client credential; plaintext token is returned once
- `DELETE /api/v1/mcp/clients/:client_id` — revoke that client without affecting other LLMs

Use `control-plane/new-mcp-client.ps1` to provision ChatGPT, Claude, Gemini, Grok, Perplexity, or another client. Each client’s `allowed_products` list is enforced by the MCP tool layer before product data or actions are exposed. Product manifests remain the second enforcement boundary for repository paths, workflows, DNS, Flow execution, and infrastructure operations.


## Automatic ChatGPT receiver

A handoff with `target_client: "chatgpt"` is automatically mirrored to the private PowerChatBridge inbox after normal MCP authentication and product-scope checks. The sending LLM needs no credential beyond its existing Clintware MCP token.

PowerChatBridge then imports the packet locally and submits it into the active ChatGPT web conversation. This provides a no-copy/paste path for ChatGPT accounts that do not expose custom MCP/Developer Mode.


## Event-driven ChatGPT receiver

ChatGPT-targeted handoffs use a persistent WebSocket receiver at `wss://mcp.codefeddy.com/api/v1/handoff-stream`. The sender still uses only its existing scoped Clintware MCP credential and calls `clintware_handoff_put` with `target_client: "chatgpt"`.

PowerChatBridge authenticates the receiver connection with the machine's existing GitHub CLI login for `clintkosh`. Clintware validates that GitHub identity live and does not persist the GitHub access token. Undelivered ChatGPT handoffs remain in RegistryHub and are replayed after reconnect until PowerChatBridge acknowledges local persistence.

The private GitHub handoff mirror remains a best-effort audit/fallback copy; it is no longer the primary delivery mechanism.

