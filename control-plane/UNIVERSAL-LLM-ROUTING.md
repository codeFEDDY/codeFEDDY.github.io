# Universal LLM Routing Through Clintware

Use this contract for any external AI client that can call MCP or HTTPS tools.

## Connection

- MCP endpoint: `https://mcp.codefeddy.com/mcp`
- Control Plane API: `https://mcp.codefeddy.com/api/v1`
- Authentication: a dedicated Clintware credential for that LLM/client in `Authorization: Bearer <credential>` or `x-api-key: <credential>`. Prefer one revocable credential per client rather than sharing the root MCP token.
- Never give the client a GitHub, Cloudflare, deployment, DNS, or other provider credential.
- GitHub identity selection happens server-side from the product manifest's `repo.identity`.

## Universal routing instruction

Give the following instruction to an LLM after its Clintware MCP connection is configured:

> Use the CodeFEDDY Control Plane at mcp.codefeddy.com as the authority boundary for this project. Start by calling `clintware_client_handshake` and, when a project/product is known, `clintware_product_manifest`. Do not ask me to switch GitHub accounts or expose GitHub/Cloudflare credentials. Resolve repository ownership, account identity, allowed paths, workflows, DNS names, and infrastructure permissions through the Control Plane. Use capability discovery/request tools for actions. If work is being continued by another model or handed back to ChatGPT, create a compact `clintware-handoff/v1` packet with `clintware_handoff_put`; return the handoff ID to me. Never put API keys, access tokens, cookies, passwords, private keys, or raw secret values in a handoff. Reuse existing project context and artifacts instead of re-fetching or re-sending the same data when possible.

## Handoff packet

The Control Plane accepts these fields:

```json
{
  "from_client": "claude|gemini|grok|perplexity|chatgpt|other",
  "target_client": "chatgpt|any",
  "product": "registered-product-slug",
  "project": "human-readable project name",
  "objective": "What is being accomplished",
  "context_summary": "Only the context required to continue",
  "repository": {
    "identity": "clintkosh|codefeddy|future-alias",
    "owner": "github-owner",
    "name": "repository-name",
    "branch": "working-branch"
  },
  "decisions": ["Decisions already made"],
  "constraints": ["Requirements that must remain true"],
  "changed_files": ["path/to/file"],
  "artifacts": ["URLs, PR numbers, deploy IDs, or artifact references"],
  "next_actions": ["Concrete next actions"],
  "notes": "Optional compact notes"
}
```

Handoffs are intentionally compact and expire from the active handoff index after seven days.

## Receiving work in another model

When the user provides a Clintware handoff ID, retrieve it with `clintware_handoff_get`, treat its explicit decisions and constraints as continuation context, then verify live repository/control-plane state before making writes.

A model must not infer that it has access to an account merely because another model did. The Control Plane determines current capability and credential availability at execution time.

## GitHub identity convention

A manifest identity maps to a Worker secret automatically:

- `clintkosh` -> `GITHUB_TOKEN_CLINTKOSH`
- `codefeddy` -> `GITHUB_TOKEN_CODEFEDDY`
- `acme-labs` -> `GITHUB_TOKEN_ACME_LABS`

Add future identities with `control-plane/add-github-identity.ps1`; no Control Plane source-code change is required.


## Provision each LLM independently

From a trusted local checkout:

```powershell
.\control-plane\new-mcp-client.ps1 -Name chatgpt
.\control-plane\new-mcp-client.ps1 -Name claude
.\control-plane\new-mcp-client.ps1 -Name gemini
.\control-plane\new-mcp-client.ps1 -Name grok
.\control-plane\new-mcp-client.ps1 -Name perplexity
```

Each command returns a different client token once. Configure that token only in that client's MCP/API authentication setting. Revoking one client does not require changing GitHub, Cloudflare, or another LLM's credentials.


## Hands-free delivery to ChatGPT without ChatGPT Developer Mode

When handing work to ChatGPT, the sending LLM should call `clintware_handoff_put` with `target_client: "chatgpt"`.

The sender uses only its existing Clintware MCP token. No extra handoff credential is required.

For `target_client: "chatgpt"`, the Control Plane automatically mirrors the sanitized packet to the private `clintkosh/PowerChatBridge` inbox. A running PowerChatBridge receiver detects the packet and submits it into the active ChatGPT web conversation. The user does not need to copy a link, handoff ID, packet, token, or prompt between models.

Do not put provider credentials or secrets in the packet. The private bridge is a context transport, not a secret transport.


## Real-time receiver behavior

For `target_client: "chatgpt"`, the handoff event is broadcast immediately through Clintware's durable WebSocket relay. PowerChatBridge receives it without polling GitHub or consuming a ChatGPT scheduled-task slot. If the receiver is offline, the stored handoff is replayed when the receiver reconnects and remains pending until acknowledged.

The source LLM does not need a receiver credential. It continues to use only its normal scoped Clintware MCP token.

