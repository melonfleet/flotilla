# Iris report: MCP for Flotilla, and how Docker Desktop does it

*Iris, 2026-10-12, for TODO item 6 ("MCP, after the assistant: design first"). Research, not a decision.*

## Summary

Flotilla should first become a narrowly scoped, local MCP server for its own fleet. For 1.5, ship a signed `flotilla-mcp` stdio helper that talks to the running app over authenticated XPC, exposes bounded read-only tools, and is off by default. Read-only fleet access can include paired hosts; actions should arrive later, initially on This Mac, with per-client grants, native Flotilla confirmations, and every operation passing through existing typed `ContainerCLI` paths and policy boundaries.

Do not copy Docker’s third-party-server hosting in 1.5. It is a separate product requiring catalog governance, image signing, secret brokering, mount and egress controls, collision handling, and audit infrastructure. Apple’s per-container VM is an excellent eventual isolation substrate, but it is not yet the complete security system Docker’s Gateway supplies.

## 1. MCP in October 2026

The current specification is **`2026-07-28`**. Its two standard transports are:

- **stdio:** newline-delimited JSON-RPC over a subprocess’s stdin/stdout. The client starts and owns the server process.
- **Streamable HTTP:** JSON-RPC POSTs to one endpoint; replies are JSON or a request-scoped SSE stream. Legacy HTTP+SSE is deprecated, not a third current standard transport. [Transport specification](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports)

The principal server surfaces are:

- **Tools:** model-selected typed functions; may read or act.
- **Resources:** URI-addressed context, normally selected or attached by the client.
- **Prompts:** user-invoked reusable templates.
- **Elicitation:** a server asks the client to obtain structured user input. In the current stateless protocol this uses an `input_required` result and retry, rather than a server-initiated request.

Tool annotations such as `readOnlyHint` and `destructiveHint` improve client UX but are advisory, not an authorization boundary. The primitives and their control model are summarized in the [MCP server overview](https://modelcontextprotocol.io/specification/draft/server/index).

For remote HTTP servers, authorization is OAuth-based and optional. A protected MCP server is the resource server; the client discovers its authorization server using Protected Resource Metadata. The current profile uses OAuth 2.1 patterns, PKCE, audience-bound tokens and resource indicators, recommends Client ID Metadata Documents, and retains Dynamic Client Registration only for compatibility. Stdio should obtain local credentials outside MCP—typically through environment/configuration—not run the HTTP OAuth flow. [Authorization specification](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization)

### What changed during the last year

`2025-11-25` added OIDC discovery, incremental scopes, CIMD registration, richer and URL-mode elicitation, JSON Schema 2020-12, and experimental durable tasks. [November 2025 changelog](https://modelcontextprotocol.io/specification/2025-11-25/changelog)

`2026-07-28` was a larger break:

- Removed `initialize`, protocol sessions and `Mcp-Session-Id`; requests now carry version, identity and capabilities, with optional `server/discover`.
- Introduced multi-round-trip `input_required` results.
- Replaced several subscription mechanisms with `subscriptions/listen`.
- Added cache hints and HTTP routing headers.
- Moved Tasks into an extension; MCP Apps became a production extension for interactive UI.
- Hardened OAuth issuer and credential binding.
- Deprecated roots, sampling, protocol logging, DCR and legacy HTTP+SSE. [Current changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog)

Because client adoption lags specification releases, Flotilla should accept both `2026-07-28` and the `2025-11-25` handshake era. The Tier-1 SDKs are TypeScript, Python, Go and C#—there is no Tier-1 Swift SDK—so a small tool-only Swift implementation needs unusually strong transcript and interoperability tests. [2026 release announcement](https://blog.modelcontextprotocol.io/posts/2026-07-28/)

### Client support

| Client | Transport and useful surface |
|---|---|
| **Claude Desktop** | Local stdio through desktop extensions/MCPB; remote connectors use HTTP from Anthropic’s infrastructure. Tools and MCP Apps are supported. Local extensions can package Node, Python or native binaries and keep marked secrets in Keychain. [Desktop extensions](https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop), [remote connectors](https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp) |
| **Claude Code** | stdio and Streamable HTTP, OAuth, tools, resources, prompts and elicitation; legacy SSE remains, and current builds also have a nonstandard WebSocket option. Project MCP configuration requires workspace approval. [Claude Code MCP reference](https://code.claude.com/docs/en/mcp) |
| **ChatGPT** | Streamable HTTP/SSE remote servers or a local/private server through Secure MCP Tunnel; it does not directly spawn arbitrary stdio servers. Supports read/write tools and MCP Apps. Generic prompt/resource browsing is not documented as a first-class ChatGPT surface. [Custom MCP servers](https://developers.openai.com/api/docs/guides/custom-mcp-server), [OpenAI MCP tools](https://developers.openai.com/api/docs/guides/tools-connectors-mcp) |
| **Cursor** | stdio, Streamable HTTP and legacy SSE with OAuth; documents tools, prompts, roots and elicitation, plus MCP Apps. Its published capability table notably does not promise generic resources. Calls require approval by default unless auto-run policy permits them. [Cursor MCP](https://docs.cursor.com/context/model-context-protocol) |
| **VS Code** | The broadest published implementation: stdio, Streamable HTTP, legacy SSE, OAuth, tools, prompts, resources, elicitation, sampling, roots and MCP Apps. Local stdio sandboxing is available on macOS/Linux. [VS Code MCP guide](https://code.visualstudio.com/api/extension-guides/ai/mcp) |
| **Others** | Raycast supports stdio/HTTP, OAuth and tool approvals. Docker also documents working integrations for Gemini, Goose, LM Studio, OpenCode, Zed and Mistral Vibe, but primitive depth varies by version. [Raycast MCP](https://manual.raycast.com/ai/model-context-protocol), [Docker client list](https://docs.docker.com/ai/mcp-catalog-and-toolkit/get-started/) |

A tools-only first server therefore reaches the reliable common denominator.

## 2. Docker Desktop’s MCP implementation

Docker divides the product into three layers:

- **Toolkit:** Docker Desktop UI for choosing MCP servers, grouping them into profiles, configuring them and connecting clients.
- **Catalog:** OCI-distributed server definitions and images. Organizations can copy or build curated catalogs.
- **Gateway:** one MCP endpoint that routes to all enabled servers, starts containerized servers on demand, injects configuration and credentials, and aggregates their tools, prompts and resources. [Toolkit](https://docs.docker.com/ai/mcp-catalog-and-toolkit/toolkit/), [Gateway](https://docs.docker.com/ai/mcp-catalog-and-toolkit/mcp-gateway)

Clients normally launch:

```text
docker mcp gateway run --profile PROFILE
```

over stdio. The Gateway can also listen using HTTP transports. `docker mcp client connect` writes supported clients’ configuration.

The CLI currently covers:

- `profile create/list/show/remove`, server add/remove, configuration and per-tool enablement;
- `catalog create/list/show/tag/pull/push` and catalog server operations;
- `gateway run`;
- `client list/connect/disconnect`;
- `secret ls/rm`, OAuth authorization/revocation;
- `tools count/ls/inspect/call`.

The newer profile/catalog commands are beta and documented for Docker Desktop 4.62+. [CLI guide](https://docs.docker.com/ai/mcp-catalog-and-toolkit/cli/)

Security is substantive but not absolute:

- Each local server runs in a container, normally capped at 1 CPU and 2 GB.
- No host filesystem access by default; bind mounts are validated and normally read-only.
- Images in Docker’s `mcp/` namespace are Docker-built, signed, accompanied by provenance/SBOM, and signature-verified by default; arbitrary third-party images do not inherit that trust.
- Secrets are stored in the Docker Desktop VM, scoped to a declared server and injected at runtime. Credentials remain until explicitly removed even if the server is removed.
- Arguments and text results are scanned for secrets; call logging defaults to tool name and argument-shape metadata rather than values.
- Tool, prompt and resource collisions are rejected.
- Network egress is **not denied globally by default**; servers may declare allowed hosts and operators can enable `--block-network`. [Gateway security details](https://github.com/docker/mcp-gateway/blob/main/docs/security.md), [Docker security FAQ](https://docs.docker.com/ai/mcp-catalog-and-toolkit/faqs/)

Dynamic MCP additionally gives the model `mcp-find`, `mcp-add`, `mcp-remove`, configuration and composition tools. That convenience is inappropriate for Flotilla’s initial owner-approval model.

Docker does not appear to expose the local Docker Desktop/Engine as a general management MCP server. Its built-in Gateway tools manage the MCP environment, while Docker’s official catalog server is for **Docker Hub** repositories, tags and discovery—not local containers. [Docker Hub MCP server](https://hub.docker.com/mcp/server/dockerhub/overview)

### What Flotilla should copy

Copy the **gateway principles**, later: profiles, one client endpoint, digest-pinned images, resource limits, no mounts or egress by default, per-server Keychain secrets, collision rejection and audit records.

Do not build this in 1.5. Apple `container` provides CPU/memory limits, read-only roots, mounts and networks, and gives each container its own lightweight VM—an attractive eventual substrate. [Apple command reference](https://github.com/apple/container/blob/main/docs/command-reference.md) But Flotilla would still need the entire trust layer above it, and current reports show that `--internal` networking should not yet be treated as proven egress denial. [Apple container issue #2062](https://github.com/apple/container/issues/2062)

## 3. How Mac apps expose MCP

Three useful patterns exist:

- **Xcode:** the client launches `xcrun mcpbridge` over stdio; Xcode must be open and the user must enable external agents. The bridge translates into Xcode’s internal XPC service. This is almost exactly Flotilla’s likely shape. [Apple setup](https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode), [XPC detail](https://cursor.com/docs/integrations/xcode)
- **Figma Desktop:** the running app hosts Streamable HTTP at `http://127.0.0.1:3845/mcp`; the user enables it in Dev Mode and manually adds that URL to a client. [Figma desktop server](https://developers.figma.com/docs/figma-mcp-server/local-server-installation/)
- **Docker Desktop:** clients launch its CLI Gateway over stdio, while Desktop owns profiles, secrets and the container backend.

There is no universal local discovery. Apps provide copyable commands/configuration or carefully edit each client’s known config after user approval.

For distribution, the helper should be nested in the app, signed with Flotilla’s Developer ID, use hardened runtime, and be included in the notarized artifact; Apple requires valid signatures and hardened runtime for every distributed executable. [Apple notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

Use XPC rather than giving the helper direct fleet or CLI access. Validate the helper’s signing identifier/team on every connection. [XPC peer-signing requirement](https://developer.apple.com/documentation/xpc/xpc_connection_set_peer_team_identity_requirement(_:_:))

App Sandbox is not itself an MCP security boundary. If Flotilla ever enables it, a helper launched by an AI client must have an appropriate sandbox of its own; it cannot assume dynamic rights from a GUI app that did not spawn it. Keeping the helper as a protocol adapter and all authority in the app minimizes that problem. [Apple’s embedded-helper guidance](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)

## 4. Security model for Flotilla

- Off by default. Add a managed setting that can lock MCP off, and optionally lock it read-only.
- Register each client in Flotilla with an app-created ID and secret; XPC authenticates the genuine helper, while the secret distinguishes Claude, Cursor, VS Code, and so on. The owner approves and can revoke each registration.
- Scopes: `read-inventory`, optional `read-sensitive`, `act-local`, later `act-fleet`. Do not equate “same Unix account” with permission.
- Use native in-app confirmation for delete, prune, kill, runtime control, machine/cluster deletion and any privileged-helper operation. Elicitation can improve UX, but must never be the security decision: a client can omit, misimplement or automatically accept it.
- Bind an approval to client, tool, normalized arguments, target host, nonce and short expiry.
- Record client, tool, target, normalized non-secret inputs, result, approval and correlation ID in Activity.
- Treat names, labels, inspect fields and logs as hostile data. Return structured, capped projections; remove control characters; mark untrusted fields; never interpolate them into tool descriptions or trusted instructions. Omit logs in 1.5, matching Greta. OpenAI likewise warns that MCP outputs can carry prompt injection. [OpenAI safety guidance](https://developers.openai.com/api/docs/guides/tools-connectors-mcp#risks-and-safety)

MCP-specific threats:

- **Tool poisoning/shadowing:** malicious metadata directs the model to misuse another tool. Use static signed descriptions, `flotilla_` namespacing, no dynamically generated tools, least-privilege client grants and server-side confirmation.
- **Rug pull:** definitions or behavior change after approval. Sign/notarize the helper, publish a schema digest/version, and require renewed approval when an update broadens tools or scopes.
- **Confused deputy:** one client induces Flotilla to exercise another user/client’s authority. Maintain per-client grants, never pass through unrelated tokens, and re-check policy at the final app/host executor. The MCP security guide describes the OAuth form of this attack. [MCP security practices](https://modelcontextprotocol.io/docs/2026-07-28/tutorials/security/security_best_practices)
- **Cross-server exfiltration:** another MCP server persuades the model to read Flotilla data and send it elsewhere. Flotilla cannot control the client’s whole context; minimize sensitive output and separately gate logs/raw inspect.

## 5. Recommended roadmap

**Flotilla 1.5**

Ship a signed stdio helper, compatible with current and previous protocol eras, connected to the running app over authenticated XPC. Expose only bounded structured tools:

- hosts and reachability;
- container list/detail/state/ports and health summary;
- images, volumes and networks;
- machines and clusters where existing policy allows disclosure;
- recent sanitized Activity;
- Flotilla guide search.

Reads may cover This Mac and paired hosts, because Q33 says the admin owns them, but Q33 does not automatically make every MCP client that admin. Continue excluding raw inspect, environment, usernames and logs unless the client receives a separate sensitive-read grant.

**Later 1.5.x/2.0**

Add optional actions in this order: start/restart, deliberate stop, recipe-backed run/pull, then destructive operations. Initially act on This Mac only; extend to hosts after audit evidence and adversarial testing.

Every action must call the same typed application operation and `ContainerCLI`; never accept argv, shell text or an executable name. Local execution retains the app’s current `MountPolicy`; remote execution must use `.remotePeer` and therefore Q14’s `WirePolicy`, deadlines, byte limits and local-only exclusions. Native confirmations sit above—not instead of—Allowlist/MountPolicy/WirePolicy.

Keep Greta’s tool set physically read-only. Sharing projections and sanitization is good; sharing MCP action tools with Greta would conflict with Q52.

Finally, defer third-party MCP hosting. ChatGPT’s tunnel or a public HTTP endpoint would create an outbound/cloud path and conflict with no-phone-home unless the owner explicitly amends that decision. Raw exec or a “Docker CLI” tool conflicts with the ban on a generic remote shell. Privileged helper calls without an owner-bound Flotilla confirmation conflict directly with the settled privilege rule.
