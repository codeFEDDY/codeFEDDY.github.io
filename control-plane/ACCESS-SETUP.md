# CodeFEDDY Control Plane Access Setup

This is the canonical credential setup for `mcp.codefeddy.com` and the `codefeddy-control-plane` Worker.

The control plane is the only component that receives infrastructure credentials. Individual products and external AI clients receive scoped control-plane credentials instead.

## Cloudflare

Create a custom API token named `Clintware MCP Control Plane`.

Scope it to the Clintware Cloudflare account and the `codefeddy.com` zone rather than all Cloudflare accounts/zones.

### Account permissions

- Account Settings: Read
- Workers Scripts: Write
- Workers KV Storage: Write
- Workers R2 Storage: Write
- Workers CI: Write
- D1: Write
- Pages: Write
- Queues: Write
- Workers AI: Write
- Vectorize: Write
- Email Routing Addresses: Write

### Zone permissions

For `codefeddy.com` only:

- Zone: Read
- DNS: Write
- Workers Routes: Write
- Zone Settings: Write
- Email Routing Rules: Write
- Cache Purge

Do **not** grant Billing, Account API Tokens Write, User API Tokens Write, membership administration, or unrestricted account administration. Those permissions are not needed for normal Clintware builds and would allow unnecessary privilege escalation.

Store the value as:

- Cloudflare Worker secret: `CLOUDFLARE_CONTROL_PLANE_TOKEN`
- GitHub Actions secret used by deployment workflows: `CLOUDFLARE_API_TOKEN`

The same high-coverage token can initially be used for both names. For stronger isolation later, issue separate deployment and runtime tokens with the same resource boundary and narrower permissions.

## GitHub

Create a **fine-grained personal access token** named `Clintware MCP Control Plane`.

- Resource owner: `clintkosh`
- Repository access: `All repositories`
- Prefer a defined expiration and rotate it before expiry.

### Repository permissions

- Actions: Read and write
- Contents: Read and write
- Workflows: Read and write
- Deployments: Read and write
- Pull requests: Read and write
- Issues: Read and write
- Pages: Read and write
- Commit statuses: Read and write
- Variables: Read and write, if the control plane needs to maintain Actions variables
- Environments: Read and write, only if the control plane needs environment configuration
- Metadata: Read (GitHub includes this automatically)

Do **not** grant repository Administration write merely for convenience. It includes destructive repository-management capabilities that the Clintware control plane does not need for normal source, branch, workflow, Pages, and deployment operations.

Store this token only as the Cloudflare Worker secret:

- `GITHUB_CONTROL_PLANE_TOKEN`

For a longer-lived integration, migrate this credential to a GitHub App later. A GitHub App can mint short-lived installation tokens while retaining the same control-plane policy layer.

## Control-plane client secrets

The Worker also uses:

- `CONTROL_PLANE_ADMIN_TOKEN` — administrative control-plane calls
- `CONTROL_PLANE_MCP_TOKEN` — trusted MCP clients

Do not give clients the Cloudflare or GitHub infrastructure credentials. Register each product/client through the control plane and let the product manifest constrain its available capabilities.

## Credential flow

`product / AI client -> scoped MCP token -> mcp.codefeddy.com -> policy + manifest -> Cloudflare/GitHub credential -> action -> audit`

This preserves one reusable Clintware integration point without exposing a literal global master key to every project.


## Multiple GitHub accounts: one-time setup

The Control Plane no longer requires all repositories to share one GitHub credential. Every project manifest can choose a `repo.identity`, and the Worker resolves that identity to `GITHUB_TOKEN_<IDENTITY>`.

### Clintware / clintkosh

The existing `CLINTWARE_GH_CONTROL_PLANE_TOKEN` GitHub Actions secret is automatically mirrored into the Worker as both:

- `GITHUB_CONTROL_PLANE_TOKEN` (legacy compatibility)
- `GITHUB_TOKEN_CLINTKOSH` (new identity-specific name)

No additional clintkosh authorization is required unless the existing token is expired or missing permissions.

### CodeFEDDY

Create one fine-grained personal access token while signed into the `codeFEDDY` GitHub account.

Recommended repository scope:

- Resource owner: `codeFEDDY`
- Repository access: only `codeFEDDY.github.io`
- Contents: Read and write
- Actions: Read and write only if CodeFEDDY later dispatches Actions
- Workflows: Read and write only if the Control Plane must modify workflow files
- Pull requests: Read and write if PR automation is wanted
- Metadata: Read

Do not grant repository Administration unless a future capability explicitly requires it.

Store the token either:

1. as the `CODEFEDDY_GH_CONTROL_PLANE_TOKEN` Actions secret in `codeFEDDY/codeFEDDY.github.io`; the deployment workflow will sync it into Cloudflare as `GITHUB_TOKEN_CODEFEDDY`, or
2. directly in Cloudflare with the helper:

```powershell
cd <your-codeFEDDY.github.io-checkout>
.\control-plane\add-github-identity.ps1 -Alias codefeddy
```

The token is entered as a secure prompt and is never written to the repository.

### Future GitHub accounts or companies

For each new account, do this once:

```powershell
.\control-plane\add-github-identity.ps1 -Alias <account-alias>
```

Then put the alias in that product's manifest:

```json
"repo": {
  "identity": "<account-alias>",
  "owner": "<github-owner>",
  "name": "<repository>"
}
```

The normalized alias determines the secret name automatically. No new Control Plane code is required.

### Verify

After deployment:

```powershell
Invoke-RestMethod https://mcp.codefeddy.com/health | ConvertTo-Json -Depth 8
```

Look for `github_identities`. Each identity should show `configured: true` and the expected repositories. The endpoint never exposes token values.


## Dedicated MCP credentials for each LLM

Do not reuse the root `CONTROL_PLANE_MCP_TOKEN` across every external AI client. After the Control Plane is deployed, create one revocable client credential per LLM.

From a trusted local checkout:

```powershell
.\control-plane\new-mcp-client.ps1 -Name chatgpt
.\control-plane\new-mcp-client.ps1 -Name claude
.\control-plane\new-mcp-client.ps1 -Name gemini
.\control-plane\new-mcp-client.ps1 -Name grok
.\control-plane\new-mcp-client.ps1 -Name perplexity
```

The helper reads `CONTROL_PLANE_ADMIN_TOKEN` from the current process environment when available; otherwise it securely prompts for it. The generated client token is displayed once. Only its SHA-256 hash is retained by the Control Plane.

Configure each client with:

- MCP URL: `https://mcp.codefeddy.com/mcp`
- Authentication: `Authorization: Bearer <that-client-token>` or the client's equivalent API-key header field
- Routing instruction: `control-plane/UNIVERSAL-LLM-ROUTING.md`

To revoke a client without disturbing the others, call `DELETE /api/v1/mcp/clients/<client-id>` with the admin credential.

