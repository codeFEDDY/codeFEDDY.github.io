# Clintware Flow

Clintware Flow is the private workflow-execution layer inside the CodeFEDDY Control Plane.

It is intentionally separate from the public **Self-Hosted Workflow Engine Builder** skill. The public skill teaches an unrelated operator how to build an independent workflow engine on infrastructure they control. It does not contain or grant access to Clintware endpoints, credentials, repositories, accounts, or private workflow definitions.

## Boundary

\`\`\`
authenticated MCP client
        |
        v
CodeFEDDY Control Plane
 identity -> client product scope -> product manifest -> capability policy
        |
        v
Clintware Flow
 workflow registry -> approval gate -> scoped capability execution -> audit
        |
        v
approved provider adapters
\`\`\`

An MCP client needs only its revocable Clintware MCP credential. GitHub, Cloudflare, research-provider, and future connector credentials remain server-side.

Per-client \`allowed_products\` is enforced before product manifests, analytics, repository actions, handoffs, or Flow operations are returned/executed.

## Current Flow step types

- \`set\`: deterministic context values.
- \`emit\`: privacy-safe internal event/audit signal.
- \`approval\`: hard pause until the caller explicitly includes that step in \`approved_steps\`.
- \`capability\`: route an existing Control Plane capability through the product manifest and risk policy.

Arbitrary shell/code execution is not a Flow step.

## Current MCP tools

- \`clintware_flow_list\`
- \`clintware_flow_get\`
- \`clintware_flow_put\`
- \`clintware_flow_run\`
- \`clintware_flow_runs\`

## Credential rule

Workflow definitions may store references such as \`credential_ref\`. They must not store secret values.

The Flow normalizer rejects credential-value field names and common token-shaped values before the workflow reaches durable storage.

Run history stores compact execution metadata only. Raw step payloads, credentials, and repository file bodies are not copied into Flow history.

## Seeded project workflows

### LandThePlane

- \`application-turbo-sprint\`: intake -> Definition-of-Done approval -> ready-for-execution event.
- \`interview-intelligence\`: meeting-complete event -> human review -> accepted-actions event.

Future connectors can add Gmail, Calendar, transcript, research, publishing, and application-state actions without replacing the workflow contract.

### Mind to Form

- \`definition-of-done\`: idea received -> mandatory Definition-of-Done approval -> approved event.

The product's existing browser gate remains the current public product behavior. Flow is the private orchestration path for future connected actions such as validation, RFQ, purchasing, and production tracking.

### OrgSynapse

- \`operating-signal\`: signal received -> review -> accepted event.

The current public prototype remains local-first. Flow becomes the private orchestration path when server-side connectors and tenant-scoped state are added.

## Extension rule

Add new Flow functionality by adding a narrowly scoped Control Plane capability/adapter first, then allowing only the products that require it.

Do not add broad provider credentials to workflow JSON.

Do not let a workflow bypass:

1. MCP client authentication;
2. client \`allowed_products\`;
3. product manifest capability policy;
4. risk/approval policy;
5. protected-path rules;
6. audit recording.

## Initial limitations

The first version is intentionally not a full n8n replacement.

It does not yet include:

- a visual node editor;
- arbitrary JavaScript nodes;
- generic shell execution;
- cron scheduling;
- webhook trigger routing;
- conditional branches;
- loop nodes;
- connector marketplace;
- durable resume from the middle of a run after an approval.

Those are additions to make only when a real Clintware workflow needs them. The internal API and stored workflow contract are designed so those capabilities can be added without giving MCP clients underlying provider credentials.

