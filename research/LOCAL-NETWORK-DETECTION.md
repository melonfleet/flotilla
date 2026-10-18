# Iris: detecting Local Network privacy failures in published container ports

**Research date:** 18 October 2026  
**Scope:** unprivileged Flotilla on macOS 26/27, driving Apple `container` 1.5.x.

**Recommendation:** build a host-side published-port diagnostic that checks an actual response through the forwarder and correlates failures with fresh runtime logs. Show **“Local Network access may be blocked”** when the evidence supports that possibility, with instructions to approve **`container-runtime-linux`** on the affected Mac. A loopback-versus-LAN TCP connection comparison alone cannot identify this problem.

Two corrections matter:

- **Local Network privacy is separate from TCC.** Reading `TCC.db` would not provide the required authorization state.
- **`kDNSServiceErr_PolicyDenied` is `-65570`.** `-65554` means `kDNSServiceErr_NoSuchRecord`. [Apple DTS on TCC](https://developer.apple.com/forums/thread/757949), [Apple’s DNS-SD header](https://github.com/apple-oss-distributions/mDNSResponder/blob/main/mDNSShared/dns_sd.h)

**Evidence labels:** **Verified** means documented or visible in inspected source; **Reported** means an upstream reproduction or the supplied Kamal account; **Inference** means a conclusion drawn from that evidence; **Unverified** identifies outstanding validation. No permission changes or network experiments were performed for this research.

**1. Why loopback can fail**

The relevant path contains two separate connections:

```text
Flotilla or another client
        │
        │ TCP to 127.0.0.1:<published-port>
        ▼
container-runtime-linux — host-side listener
        │
        │ separate TCP connection to <guest-IP>:<container-port>
        ▼
Application inside the container VM
```

**Verified:** the 1.5.0 runtime constructs separate host listener and guest destination addresses. The destination comes from the container’s network attachment. This forwarding path uses IP networking to reach the guest. [1.5.0 runtime source](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/Services/RuntimeLinux/Server/RuntimeService.swift)

**Reported:** upstream issue #2029 describes a published loopback port accepting traffic and then resetting the client connection. The runtime recorded a backend connection failure with `errno: 65`, “No route to host.” A contributor reproduced failure and recovery by switching `container-runtime-linux` Local Network access off and on; direct guest-IP access from their client remained functional. The issue also records an early macOS 27 beta regression where the prompt and Settings entry were missing, reportedly fixed in beta 7, build `26A5421a`. Those observations concern specific builds, principally `container` 1.1–1.2.2; they are corroboration, not a fresh 1.5.x reproduction. [apple/container #2029](https://github.com/apple/container/issues/2029)

**Inference:** Kamal’s 13 October account fits a denial of the **forwarder-to-guest connection**. Loopback’s exemption protects the first connection; it does not exempt the helper’s subsequent connection to the VM network.

Consequently:

- A successful TCP handshake with `127.0.0.1:<port>` may establish only that the forwarder is listening.
- An HTTP request, TLS handshake with the expected server, or other appropriate exchange can still fail afterward.
- Both loopback and LAN clients can fail through the same blocked backend.
- Loopback success with LAN failure is possible, but does not uniquely identify this permission problem.

The upstream `ConnectHandler` source explicitly connects to the backend after the frontend connection becomes active, and closes the frontend on backend connection failure. [Forwarder source](https://github.com/apple/container/blob/main/Sources/SocketForwarder/ConnectHandler.swift)

**2. What macOS applies the permission to**

Local Network privacy arrived on macOS with Sequoia 15. Apple introduced the macOS feature at WWDC24; the current guidance and 2025–2026 reports remain the relevant basis for 26/27. [WWDC24: What’s new in privacy, Local Network segment](https://developer.apple.com/videos/play/wwdc2024/10123/?time=1134)

Apple’s current rules distinguish launch contexts:

| Process or context | Documented treatment |
|---|---|
| Ordinary GUI app or user LaunchAgent | Subject to Local Network permission. |
| System daemon started by `launchd` | Automatically allowed. |
| Process running as root | Automatically allowed. |
| CLI tool launched from Terminal or SSH, including its children | Automatically allowed. |
| Helper spawned by an app | macOS attempts attribution to the responsible app. |

Identity uses responsible-code attribution and code signing; executable UUID also matters. State is per user. Non-`SMAppService` LaunchAgents can identify their responsible app using `AssociatedBundleIdentifiers`. [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

**Inference:** being called a “CLI helper” or “VM networking helper” creates no blanket exemption. The actual launch context matters. Running a diagnostic from Terminal can therefore give different results from running equivalent code inside Flotilla.

The container project uses per-user launch services; an upstream CI request specifically describes its API server in `gui/<uid>`. Starting `container` from Terminal does not mean every separately registered runtime service inherits Terminal’s treatment. [apple/container #1514](https://github.com/apple/container/issues/1514)

The project has documented the need to approve `container-runtime-linux` since July 2025. That is the expected permission identity for this incident; Flotilla’s own discovery and management permission must be treated separately. [apple/container #370](https://github.com/apple/container/issues/370)

**Unverified:** the exact responsible-code chain on Kamal’s machine, including installation channel, executable path, signature and launch domain.

**The prompt and stored decision**

A September 2026 Homebrew report records this prompt, including a truncated executable name:

> Allow “container-runti” to find devices on local networks?

The same report identifies full `container-runtime-linux` entries in Settings. Flotilla should tell users the full name while allowing for truncation and OS-specific presentation. Exact wording, secondary text and button labels on Kamal’s build remain **unverified**. [Homebrew #312547](https://github.com/Homebrew/homebrew-core/issues/312547)

The supported user control is **System Settings → Privacy & Security → Local Network**.

**Do not implement a TCC database reader.** Apple DTS explicitly says Local Network privacy does not use the TCC infrastructure reset by `tccutil`. Contemporary reports associate implementation state with NetworkExtension preferences and policy enforcement; that is private implementation detail, not an authorization-query contract. [Apple DTS](https://developer.apple.com/forums/thread/757949), [2026 NetworkExtension diagnostic report](https://developer.apple.com/forums/thread/844209)

**Plain answer about Full Disk Access:** an ordinary app without FDA cannot rely on reading the protected TCC databases. FDA is normally required to access them, and even FDA does not make their location, schema or accessibility a supported API. Flotilla should neither request FDA nor read `TCC.db` for this feature. [Apple DTS on database access](https://developer.apple.com/forums/thread/114452)

**3. Traffic and observable failures**

Local means on-link networking, rather than simply private address ranges. Outgoing TCP/UDP operations can require access; accepting incoming TCP does not. Loopback itself is exempt. The guest-facing connection remains the relevant operation here. [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

| Observation | Interpretation |
|---|---|
| Helper logs `EHOSTUNREACH`, Darwin errno `65` | Verified as an observed privacy-related failure, but also compatible with a real routing failure. |
| `ENETUNREACH`, Darwin errno `51` | Generic network-unreachable result. **Unverified as the signature of this specific container failure.** |
| `NWConnection` waits and its current path reports `.localNetworkDenied` | Evidence about the operation performed by that connection’s process. |
| Bonjour reports `.dns(-65570)` | `kDNSServiceErr_PolicyDenied`; relevant to the Bonjour operation, not an authorization query for the runtime. |
| `.dns(-65554)` | No such DNS record; do not classify it as policy denial. |
| Client receives a reset, EOF or timeout | Compatible with failed forwarding, but not permission-specific. |
| TCP handshake succeeds | Listener reachable; backend forwarding may remain untested. |

Apple DTS reproduced `EHOSTUNREACH` in a LaunchAgent privacy failure on macOS 15.3.2. The DNS constants are independently confirmed in Apple’s header and the installed SDK. [LaunchAgent investigation](https://developer.apple.com/forums/thread/778457), [DNS-SD constants](https://github.com/apple-oss-distributions/mDNSResponder/blob/main/mDNSShared/dns_sd.h)

Pending approval and explicit denial need not produce distinguishable client behavior. Network-framework operations can wait, while direct socket operations fail; application deadlines can turn either situation into a timeout. Apple’s WWDC20 session explains these API differences, although its examples are iOS-era. [WWDC20: Support local network privacy](https://developer.apple.com/videos/play/wwdc2020/10110/)

**Flotilla cannot infer that a prompt is currently visible from a failed connection.** Suitable wording is “access may be blocked or awaiting approval,” not “a permission dialog is open.”

**4. Detection options, ranked**

The ranking below concerns **confidence in the cause**. The preferred shipping implementation combines row 2 with probes; row 1 is stronger evidence when available, but has poorer operational reliability.

| Rank / option | Reliability | False positives | False negatives and limits | Remote host |
|---|---|---|---|---|
| **1 — (c) Explicit system policy-denial log tied to the helper** | Strongest causal evidence when identity and time match. | Stale entry, another installed copy, another user or unrelated operation. | Missing, redacted or inaccessible logs; changed wording; no persisted event. | Collect on affected host. Availability must be tested there. |
| **2 — (b)+(e) Fresh runtime backend error correlated with a failed published-port exchange** | Practical evidence for a probable problem. | Broken route/bridge, VPN or network filter, unreachable guest. | Logging unavailable, alternate log destination, changed format, wrong container correlation. | Yes, through bounded host-side collection. |
| **3 — (a) Loopback/LAN response comparison** | Useful localization; weak permission attribution. | Bind address, firewall, client isolation, wrong address/family, service readiness or protocol mismatch. | Both paths share the blocked backend; TCP-only probes can pass. | Yes locally on host; actual LAN reachability also needs another device. |
| **4 — (b) Process/listener presence; (e) `system status`** | Establishes runtime or listener existence. | Healthy process/status mistaken for healthy forwarding. | No authorization information; misses this incident. | Yes. |
| **Unavailable — (d) Public authorization query for another process** | No documented facility. | A Flotilla permission result misattributed to the runtime. | Cannot inspect the helper’s state. | Same limitation remotely. |

**(a) How to probe usefully**

Use a bounded diagnostic with separate observations:

1. **Guest service:** connect to the inspected guest IP and container port.
2. **Published loopback endpoint:** test it where the mapping includes loopback.
3. **Published host address:** test the applicable host LAN address where the mapping includes it.
4. **External LAN client:** optionally test from an admin Mac or another peer.

Record TCP establishment and application exchange separately. For a known HTTP service, a valid response—including an expected authentication error—can establish forwarding. For an unknown service, do not send arbitrary HTTP: report **“listener reachable; forwarding unverified”** unless a suitable exchange is available.

Respect explicit bindings. A mapping to `127.0.0.1` is intentionally unavailable through the LAN address; a mapping to a particular LAN address need not answer on loopback.

A host connecting to its own LAN address does not reproduce packets arriving from another machine. **Unverified:** whether every relevant 26/27 build applies the same privacy treatment to self-addressed traffic. Treat that comparison as a localization aid.

Suggested interpretation:

| Results | Flotilla conclusion |
|---|---|
| Guest service responds; published exchange fails; helper reports fresh backend `EHOSTUNREACH` | Local Network access is a plausible cause; show repair guidance. |
| Loopback exchange works; external LAN exchange fails | Investigate binding, firewall and LAN path first. |
| Guest and published paths both fail | Broader service/network problem; permission cause unresolved. |
| Fresh helper-specific policy denial accompanies failure | macOS reported a Local Network denial for the helper. |
| Expected response succeeds | This endpoint worked at this time. |

These are proposed diagnostic rules, **not validated thresholds**.

A particularly important competing cause is upstream #2051: bridge reuse and teardown can destroy another container network’s connectivity. The workspace’s 1.5.0 research also records published listeners remaining present during that failure. [apple/container #2051](https://github.com/apple/container/issues/2051), [local 1.5.0 investigation](research/CONTAINER-UPGRADE-1.5.0.md:97)

**(b) Runtime processes and logs**

Prefer:

```sh
container system logs --last 2m
```

Correlate a deliberately timed probe with:

- Runtime process/PID and container identifier.
- Published endpoint.
- `backend - connect failed`.
- Numeric error and timestamp.

Do not interpret process existence, successful `listen()`, or a “creating forwarder” message as authorization success.

`container logs <id>` reports container workload output, with optional boot logging; it is not the normal source for the macOS helper’s socket failures. Use it to assess guest application readiness. [1.5.0 command reference](https://raw.githubusercontent.com/apple/container/1.5.0/docs/command-reference.md)

**(c) Unified logging**

Useful investigation commands are:

```sh
/usr/bin/log show --last 2m --style json --info \
  --predicate 'subsystem == "com.apple.container" AND process == "container-runtime-linux"'
```

```sh
/usr/bin/log show --last 2m --style json --info --debug \
  --predicate '(process == "nehelper" OR process == "nesessionmanager" OR subsystem == "com.apple.networkextension") AND (eventMessage CONTAINS[c] "local network" OR eventMessage CONTAINS[c] "necp")'
```

These predicates are **investigation examples, not stable detection APIs**. Start broadly enough to discover the relevant message, then correlate identity and time. The runtime’s log metadata can distinguish containers; NetworkExtension messages may identify a binary or signing identity instead.

A 2026 report contains `nehelper` messages explicitly describing denial by preference. Its root-cause analysis is the reporter’s; Apple DTS requested the Feedback number rather than confirming that analysis. [Developer Forums report](https://developer.apple.com/forums/thread/844209)

A predicate for `tccd` or `com.apple.TCC` is not the primary Local Network investigation.

**Entitlements and access:**

- Launching `/usr/bin/log show` is different from opening the system store with `OSLogStore`.
- Flotilla needs no special entitlement merely to launch the CLI, but that does not guarantee visibility of every other process’s messages.
- Apple documents an admin-account and `com.apple.logging.local-store` requirement for `OSLogStore.local()`. Do not assume in-process system-wide access is available to an ordinary app. [Apple API documentation](https://developer.apple.com/documentation/oslog/oslogstore/local%28%29)
- **Unverified:** which runtime and NetworkExtension records Flotilla can read under standard-user, admin-user and sandboxed configurations on the target 26/27 builds.

Missing logs must produce **“diagnostic evidence unavailable”**, never **“permission allowed.”** `--debug` also cannot recover events that were never retained.

**(d) Public APIs**

Apple documents no general authorization-status query even for the current process; none is documented for another PID or signature. `NWConnection` can expose `.waiting` with `currentPath.unsatisfiedReason == .localNetworkDenied` for its own operation. [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

Use that to identify **Flotilla’s own** blocked probe or management connection. It cannot establish `container-runtime-linux`’s authorization. A loopback connection to the forwarder likewise cannot expose the helper’s backend `NWPath`.

**(e) What `container` exposes**

**Verified in 1.5.0:** `system status` checks service registration/API responsiveness and returns versions, host information, paths and resource counts. It provides no Local Network authorization field or published-port health result. [1.5.0 status implementation](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/ContainerCommands/System/SystemStatus.swift)

`system logs` supplies diagnostic text, not structured permission state. The inspected upstream implementation invokes `log show`/`log stream`, filtering `com.apple.container`; it therefore does not include unrelated NetworkExtension messages. The implementation inspected here is `main`, while command availability and flags were checked against 1.5.0 documentation and workspace captures. [System logs source](https://github.com/apple/container/blob/main/Sources/ContainerCommands/System/SystemLogs.swift)

If the runtime was started with `--log-root`, service messages go to files and `system logs` shows none. Use the reported log destination where readable; do not restart the runtime merely to change logging. [1.5.0 logging documentation](https://raw.githubusercontent.com/apple/container/1.5.0/docs/command-reference.md)

**5. What 1.5.0 already does about prompting**

An important update to the original 2025 issue: PR #1248 merged on **25 February 2026**, adding an attempt to trigger the permission alert before publishing ports. The 1.5.0 runtime source confirms that call remains in `startSocketForwarders`. [PR #1248](https://github.com/apple/container/pull/1248), [1.5.0 runtime](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/Services/RuntimeLinux/Server/RuntimeService.swift)

The utility connects UDP sockets to generated IPv6 link-local destinations without sending application data. It explicitly describes prompting as best effort, discards connection results and returns no authorization status. **Inference from the code:** an unavailable suitable interface can also leave it with nothing to attempt. [Prompt utility and original call site](https://github.com/apple/container/pull/1248/files)

Thus successful container startup does not establish approval. Flotilla should not duplicate this operation in its own process expecting to authorize the runtime.

**6. User-facing repair**

For both **macOS 26 and macOS 27**, instruct:

**Apple menu → System Settings → Privacy & Security → Local Network → enable `container-runtime-linux`.**

This is Apple’s documented Settings path, also present in the 26/27 container reports. The exact screen presentation on Kamal’s installed build remains to be captured. [Apple’s Mac guide](https://support.apple.com/guide/mac-help/control-access-to-your-local-network-on-mac-mchla4f49138/mac), [macOS 26 guide](https://support.apple.com/guide/mac-help/control-access-to-your-local-network-on-mac-mchla4f49138/26/mac/26)

Proposed message when only circumstantial evidence exists:

> **Published ports aren’t responding on Mac Studio**
>
> macOS Local Network access may be blocking Apple’s container forwarding helper.
>
> On **Mac Studio**, approve the Local Network prompt for **container-runtime-linux**, or enable it in **System Settings → Privacy & Security → Local Network**. Then choose **Check Again**.

For a correlated policy-denial event, replace “may be blocking” with “reported a Local Network denial for.”

Offer **Open System Settings**, **Check Again**, and **Show Diagnostic Details**. On remote hosts, identify the affected Mac explicitly; opening Settings on the admin Mac cannot repair its host. A deep link directly to the Local Network pane should be treated as **unverified implementation convenience**, with the written path always available.

Retry using fresh client connections after approval. Do not require a runtime restart as the first step. If recovery needs one, explain that restarting the runtime interrupts its containers.

**Can the prompt be raised again?**

There is **no supported `tccutil` Local Network service name**. Do not prescribe `tccutil reset LocalNetwork`, `SystemPolicyNetworkVolumes`, or `All` as this repair. Apple DTS explains the separation from TCC; current Apple guidance provides no macOS reset to “undetermined.” [Apple DTS](https://developer.apple.com/forums/thread/757949), [TN3179 reset guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy#Reset-local-network-state)

An undetermined helper may prompt when it performs the relevant operation. An already denied helper should be repaired through Settings. Restarting a process is not a permission reset.

For clean first-run testing, use a fresh user account or restore a clean macOS VM snapshot. Do not build a repair around deleting private policy files.

**Does approval survive an upgrade?**

**Do not promise it.** Upstream explicitly warns that an executable upgrade may require approval again. Stable signing is intended to support stable identity, but deployment and OS bugs can interfere. [Container #370](https://github.com/apple/container/issues/370), [Apple DTS on stable signing](https://developer.apple.com/forums/thread/787469)

A September–October 2026 Homebrew report describes duplicate runtime entries and trouble enabling the current version after upgrades. It reports ad hoc signing and changing versioned paths; its embedded automated signature analysis is **not independently verified here**. [Homebrew #312547](https://github.com/Homebrew/homebrew-core/issues/312547)

Recheck functionality after upgrades and record the actual running helper’s path and signing identity when diagnosing duplicate entries. A changed binary hash alone is not proof that approval was lost.

**7. Flotilla implementation and remote-host scope**

The inspected workspace already has a typed remote `probePort(container:port:)` call. Its documented purpose is a connection to the container’s own address; that does not exercise a published host port. Also, `system logs` is absent from the current command allowlist. These are implementation gaps, not existing detection capabilities. [Remote host calls](Sources/FlotillaCore/Wire/WireHostCalls.swift:61), [allowlist](Sources/FlotillaCore/Allowlist.swift:1060)

Proposed work:

- Add a bounded diagnostic taking a container and an existing published mapping; derive targets from inspected state.
- Preserve separate guest, listener and application-response observations.
- Collect narrowly bounded runtime logs, with explicit collection-failure results.
- Return evidence and confidence, rather than an invented authorization Boolean.
- Run the same diagnostic on the affected host and return its results over the authenticated management connection.
- Limit payload capture; avoid retaining application response bodies or unrelated system logs.

A remote check needs the same runtime-owning user context. SSH probes can be useful controls, but cannot prove that the GUI app or runtime helper has equivalent access. If Flotilla cannot establish its management connection, host-side diagnosis is unavailable until another access path is used.

A future upstream improvement would be a diagnostic performed **inside the runtime helper** against the guest destination, returning a structured policy-denied result when available. That would eliminate much of Flotilla’s cross-process inference. This is a proposal; no such interface was verified.

**8. Open questions for Kamal**

1. **Exact environment:** macOS version/build, `container` CLI and server versions, installation channel and recent upgrades.
2. **Approval identity:** full prompt wording and Settings entry; whether duplicate runtime entries appeared.
3. **Original failure:** did `127.0.0.1` fail during TCP establishment, reset after sending data, or time out? Did guest-IP access work?
4. **Bindings:** were affected ports published to loopback, all addresses or a specific LAN address? Were UDP mappings affected too?
5. **Recovery:** did existing containers recover immediately after approval, after fresh client connections, or only after a restart?
6. **Evidence:** can the runtime logs around the original failure identify the backend error and container? Was custom file logging enabled?
7. **Competing causes:** VPN, network filter, custom container networks, or missing bridge/gateway at the time.
8. **Validation opportunity:** on a disposable setup, can switching the helper’s permission reproduce and clear the failure while a known guest service remains healthy?

The key unresolved engineering checks are unprivileged log visibility on the target builds, actual 1.5.x before/after behavior, and reliable attribution to the running helper when multiple installations exist. Until those checks pass, Flotilla can detect failed forwarding and explain the likely repair, but should retain an **unknown** authorization state.
