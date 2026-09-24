# Jira access through the CodeFEDDY Control Plane

Jira is integrated as a server-side Clintware capability. QuillGeist Lite ("qq") can initiate authorization and authorized MCP clients can use Jira tools, but neither qq nor an external model receives the Atlassian access token, refresh token, or client secret.

## Architecture

```text
authorized MCP client / qq
        |
        v
mcp.codefeddy.com
  client + product scope
  quillgeist-lite Jira capability
  audit
        |
        +--> Atlassian OAuth 2.0 (3LO)
        |      encrypted rotating refresh grant
        |
        v
api.atlassian.com/ex/jira/{cloudId}/rest/api/3
```

The Jira user's normal Jira project and issue permissions remain authoritative. Clintware does not elevate them.

## Atlassian app: one-time setup

Create one OAuth 2.0 (3LO) integration in the Atlassian Developer Console.

Use this callback URL exactly:

```text
https://mcp.codefeddy.com/api/v1/jira/oauth/callback
```

Grant these scopes:

```text
read:jira-work
read:jira-user
write:jira-work
offline_access
```

The first three are the classic Jira scopes used by the adapter. `offline_access` is required for refresh tokens.

The Control Plane uses these GitHub Actions secrets in `codeFEDDY/codeFEDDY.github.io`:

- `ATLASSIAN_CLIENT_ID`
- `ATLASSIAN_CLIENT_SECRET`
- `JIRA_TOKEN_ENCRYPTION_KEY`

You normally do **not** need to create these manually. If Jira is not yet configured, qq's `connect-jira` task now:

1. detects which secret names are missing;
2. prompts locally for the Atlassian Client ID and Client Secret;
3. sends those values directly from the local machine to GitHub Actions secrets through the authenticated `gh` CLI;
4. generates a dedicated high-entropy `JIRA_TOKEN_ENCRYPTION_KEY` locally when needed;
5. triggers `Deploy CodeFEDDY Control Plane`;
6. waits until the public health check confirms the Jira adapter is configured;
7. then opens the Atlassian OAuth consent flow.

The Client Secret is entered with a secure PowerShell prompt. Neither the Client Secret nor the generated encryption key is written to source, sent through ChatGPT, included in the qq job payload, or printed in task logs.

Advanced/manual setup is still supported by creating the three repository secrets yourself and running the normal deployment workflow.

## Connect from qq

The qq task registry contains:

```text
connect-jira
```

Dispatch it through the existing `clintware_quillgeist_lite_run` MCP tool. It is intentionally a one-command bootstrap:

1. verifies the local GitHub CLI identity;
2. self-configures the Control Plane's Jira provider secrets when they are not already active;
3. triggers and waits for the Control Plane deployment when configuration changed;
4. requests a short-lived Atlassian authorization URL;
5. opens Atlassian in the default browser;
6. waits for the Control Plane callback;
7. confirms the connected Jira site(s).

After the provider secrets are established, later `connect-jira` runs skip provisioning and go directly to OAuth authorization. The Atlassian access/refresh token never passes through the local task payload or qq logs.

## MCP tools

Read:

- `clintware_jira_status`
- `clintware_jira_sites`
- `clintware_jira_projects`
- `clintware_jira_search`
- `clintware_jira_get_issue`
- `clintware_jira_transitions`

Authorization:

- `clintware_jira_oauth_start`

Write:

- `clintware_jira_create_issue`
- `clintware_jira_update_issue`
- `clintware_jira_add_comment`
- `clintware_jira_transition_issue`

A scoped MCP client must be allowed to access the `quillgeist-lite` product. The product manifest separately requires `jira.read:quillgeist-lite` or `jira.write:quillgeist-lite`.

If more than one Jira Cloud site is authorized, callers must provide the desired `cloud_id`. With exactly one site, it is selected automatically.

## Token lifecycle

The Control Plane requests `offline_access`. Atlassian refresh tokens rotate. Every successful refresh replaces the stored refresh token atomically with the newly returned token.

Stored grant data is AES-GCM encrypted before it is written to the Control Plane Durable Object. Public health/status surfaces expose only configuration state, safe scope names, and Jira site metadata.

## Disconnect

Delete the stored Clintware grant with:

```http
DELETE /api/v1/jira
Authorization: Bearer <authorized Clintware/admin/GitHub receiver credential>
```

Also revoke the app from the Atlassian account if complete provider-side revocation is required.

