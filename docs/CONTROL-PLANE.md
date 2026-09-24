# CodeFEDDY Control Plane

Canonical infrastructure boundary for CODE FEDDY.

- Website repository: codeFEDDY/codeFEDDY.github.io
- Primary site: https://codefeddy.com
- MCP/control plane: https://mcp.codefeddy.com
- Identity broker target: https://auth.codefeddy.com
- Local runner: CodeFEDDY qq under quillgeist-lite/

The CodeFEDDY control plane is modeled on the proven Clintware architecture but has its own repository, domains, Worker, credentials, manifests, telemetry namespace, local runner, and deployment workflows.

## Identity boundary

No CodeFEDDY page or production application is hosted from a Clintware repository. Clintware may be used only as a temporary migration/dispatch transport while the CodeFEDDY runner is being bootstrapped.

## Security

Provider credentials remain server-side. MCP clients receive scoped, revocable capability credentials. The local runner uses an outbound event-driven channel and an allowlisted task registry rather than arbitrary remote shell execution.
