# Flotilla — consolidated feature list (decision document)

Merged from `research/design-ux.md` (**UX**), `research/preferences-settings.md` (**SET**),
`research/features-runtime.md` (**RUN**), `research/deployment-ops.md` (**OPS**), filtered
through `PLAN.md` and `DECISIONS.md`. Deduped: where several researchers proposed the same
thing, it appears once with all source tags.

**Legend:** `[core]` = build it in that phase · `[later]` = deferred, keep the door open ·
`[skip]` = don't build. Section headings are the PLAN.md phase. **⚠** = touches a settled
doc; see §7.

---

## 1. Executive summary

The research converges on a clear product: **a table-first fleet console with a shallow
menu-bar popover**, wrapping a CLI that is far smaller than Docker's — which is good news,
because it deletes half the feature list before we start (no compose, no events, no pause,
no VM-sizing pane). The differentiator no comparable has is the **cross-host container list**;
the differentiator that costs the most is **polling discipline**, since `container` has no
event stream. Phase 1 is bigger than PLAN.md implies (preflight, security baseline, settings
registry all want to land there), and Phases 2–4 hinge on one protocol decision made now.

**The decisions only you can make:**

1. **Wire shape — CLI-args passthrough vs. typed bounded operations.** RUN and OPS
   genuinely disagree; it sets the cost of every later feature. (§6, Q1)
2. **Table vs. the card grid** in `design/dashboard-mockup.html` as the default view. (§6, Q2)
3. **Does host mode become stateful?** Restart/health and remote settings both want to live
   on the host peer, which expands "host mode just runs CLI args". (§6, Q3)
4. **Two-tier managed settings (`defaults` + `locked`) + a typed settings registry** —
   near-free now, a rewrite of every settings accessor later. (§6, Q4)
5. **Phase 1 scope**: approve §2 as-is, or cut it to containers+images+logs only. (§6, Q5)

---

## 2. Phase 1 — Local MVP · **proposed v1 scope (approve or trim this section)**

### 2.1 Core runtime features

| Feature | One-line | From | Rec |
|---|---|---|---|
| Container list | `ls --all --format json` → state, name (`configuration.id`), image, ports, CPU/mem, started; one call returns everything | RUN, UX | **[core]** |
| **Table view, sortable/resizable/hideable columns** | Running-first default sort; cards become an alternate "Cards" toggle **⚠ changes the mockup's premise** | UX | **[core]** |
| Lifecycle actions | start / stop / restart / kill / delete; `restart` = stop+start (no native cmd); `--signal`/`--time` behind a disclosure | RUN, UX | **[core]** |
| Run sheet | One scrollable sheet (not a wizard): image, name, `-d -e -p -v --mount -c -m --network --init --stop-signal` | RUN | **[core]** |
| **Live command preview + "Copy `container` command"** | Shows the exact CLI before it runs, everywhere; teaches the CLI and doubles as the audit string | RUN, UX | **[core]** |
| Logs viewer | `logs -n N`, follow toggle, search+highlight, timestamps, wrap, copy/save, capped ring buffer, **`--boot` toggle** (micro-VM boot log — unique to this runtime) | RUN, UX, SET | **[core]** |
| Inspect tab | Pretty JSON + friendly summary; free, `ls` already returns the whole object | RUN, UX | **[core]** |
| Stats (snapshot) | Computed CPU % from Δ`cpuUsageUsec` (two samples), mem %, net/block IO — **numbers, not sparklines** | RUN, UX | **[core]** |
| Search + filter grammar | `is:running` / `is:stopped` tabs that write into the search field, plus `image:`, `host:`, free text; ⌘F focuses | UX, RUN | **[core]** |
| Multi-select bulk actions | stop/kill/delete/restart; use native `-a` when the selection is everything | RUN, UX | **[core]** |
| Images | list, pull (with `--progress`), delete, prune, tag, inspect; hide `architecture:"unknown"` attestation variants | RUN | **[core]** |
| Volumes + networks | list/create/delete/inspect/prune — cheap. **⚠ UX wants these on one "System" page**, not new nav items | RUN, UX | **[core]** |
| `system df` disk panel | One call; answers "why is my disk full" | RUN | **[core]** |
| Clickable ports/addresses | Open `http://<ip>:<port>`; row context menu with a Copy submenu (ID, image, IP, port URL) | UX, RUN | **[core]** |
| ⌘K command palette | Over containers, images, actions (+ hosts from Phase 3). **UX would slip it to Phase 3 if Phase 1 gets tight** | RUN, UX | **[core]** |
| Registry login/logout/list | Local-only is fine for v1; remote login needs stdin frames (see §7) | RUN, SET | **[later]** |
| Image build UI | `build -f -t --build-arg --no-cache -o`; long output stream — do it after Phase 4 streaming | RUN, UX | **[later]** |
| `save`/`load`/`export` | Niche locally; becomes interesting as host→host image transfer in Phase 3 | RUN | **[later]** |
| Per-container nickname / tint / icon | Pure polish; local metadata in SwiftData | RUN | **[later]** |
| Saved run configs / templates | Much more valuable once "run this on host N" exists | RUN | **[later]** |

### 2.2 Shell, onboarding, and preflight

| Feature | One-line | From | Rec |
|---|---|---|---|
| **Preflight checklist with inline remediation** | binary present → version → `system status` (`"unregistered"` = service down) → kernel installed; per-row fix button, Re-run, badge on nav, **and a "Continue anyway" escape (never a trapping modal)** | UX, RUN, OPS | **[core]** |
| Guided `.pkg` install | Downloads the signed Apple release, verifies it, hands it to the system installer with visible authorization — confirms DECISIONS.md | UX, RUN, OPS | **[core]** |
| `kernel set --recommended` flow | A fresh Mac fails without it, and the CLI's prompt can't be answered from a non-TTY | RUN | **[core]** |
| Two surfaces: `MenuBarExtra(.window)` + main window | Popover = glance + quick actions only; window is the primary UI. **⚠ deviates from HIG's "menu, not popover"** (justified: per-host dots/counts exceed `NSMenu`) | UX, RUN | **[core]** |
| "Show in: Menu bar / Dock / Both" | Required by HIG + `NSStatusBar` docs; defuses the `LSUIElement` auto-termination trap. **⚠ extends PLAN's "menu-bar app" framing** | UX, SET | **[core]** |
| Menu-bar glyph = monochrome template | State by shape/badge, not colour (idle / working / attention) | UX | **[core]** |
| Main-window IA capped at 3–4 nav items | Sidebar Fleet · content Containers/Images · inspector tabs. If we ever need "customize nav", the IA is already wrong | UX | **[core]** |
| Status vocabulary | Drive from `status.state` + app-level states (starting, action failed, host unreachable); render **dot + SF Symbol + text**, never colour alone. **⚠ pink is brand/selection — needs a separate error colour in `branding.md`** | UX | **[core]** |
| Empty states carrying the primary action | No containers → "Run a container"; filtered-empty → "Clear filter"; not installed → the preflight card | UX | **[core]** |
| Progress sheet for long ops | `.pkg` install, pull, build, export: determinate where the CLI gives it, collapsible+searchable log, Cancel, run-in-background | UX | **[core]** |
| Destructive-action policy | Confirm with the object named, count on bulk, "don't ask again"; **never a confirmation inside the popover**; `prune` always previews exactly what dies | UX, RUN, SET | **[core]** |
| Quit semantics stated in the menu item | "Quit Flotilla — containers keep running" (Docker's ⌘Q ambiguity is its most-cited UX failure) | UX | **[core]** |
| Dark mode + accessibility baseline | Light/Dark/Increase Contrast/Reduce Transparency passes; keyboard-reachable everything, VoiceOver status in words, no hover-only affordances, Reduce Motion kills glass morphs | UX | **[core]** |
| Liquid Glass placement | Glass on popover chrome, toolbar, sidebar, control clusters (one `GlassEffectContainer`); **tables and cards stay opaque**; never glass-on-glass | UX | **[core]** |
| Sparklines on cards | Needs streaming; Phase 1 ships numeric cells. **⚠ mockup shows sparklines** | UX, RUN | **[later]** |
| Dockerfile drag-to-build | The one concrete feature request in the Davit HN thread | UX | **[later]** |

### 2.3 Settings, data layer, security baseline

| Feature | One-line | From | Rec |
|---|---|---|---|
| **Typed settings registry** | `SettingsKey<T>` (name, type, default, scope `.app/.host/.perHost`, `requiresRestart`) + static registry; the Settings UI, Wire get/set, Jamf key list and export all derive from it | SET | **[core]** |
| Four stores, one job each | `UserDefaults` (scalars, free MDM override) · Keychain (identity, fingerprints, creds) · SwiftData (hosts, history) · **separate window/UI state** so "reset settings" doesn't move your window | SET | **[core]** |
| Schema `version` integer + migration | One field on day one; saves a corrupt-prefs bug later (Rancher's `"version": 18`) | SET | **[core]** |
| Precedence model | built-in < managed `defaults` seed < user < per-host override < managed `locked`. **⚠ upgrades `jamf-config-profile.md`'s single "managed wins" rule** | SET, OPS | **[core]** |
| General prefs | Launch at login (`SMAppService`, off) · show in menu bar/Dock/both · theme System/Light/Dark · **poll interval (default 5 s, "Off" allowed)** · confirm-before-destructive (on) | SET | **[core]** |
| CLI integration prefs | Path to `container` (+ detect) · auto-start the API service (default: ask) · detected version + check for newer release | SET | **[core]** |
| Defaults for new containers | Default CPUs/memory (applied as `-c`/`-m`) and default registry — mirroring `[container]`/`[registry]` in config.toml | SET | **[core]** |
| Three separate resets | *Reset preferences* ≠ *Forget all hosts and trust* ≠ *Reset window layout*. **Never offer to delete container/image data from a settings reset** | SET, OPS | **[core]** |
| **Uninstall/data semantics defined before creating state** | Four layers: app · Flotilla prefs+logs · Keychain identity+trust · Apple's runtime and its data. Trashing the app destroys none of the others | OPS | **[core]** |
| Hardened runtime + Developer ID + notarize/staple | Sign every nested binary, secure timestamps, drop `get-task-allow`, keep library validation; verify with `codesign`/`spctl` + clean-Mac launch. Build hygiene now, distribution in Phase 5 | OPS | **[core]** |
| **No App Sandbox for v1** | We execute an external CLI and later listen for connections; a useful sandbox needs brittle exceptions. **⚠ a deliberate clarification DECISIONS.md doesn't currently record** | OPS | **[core]** |
| Minimal entitlements inventory | No JIT, unsigned memory, DYLD, Apple Events, broad Keychain group; add local-network usage string + declared Bonjour service before Phase 2 | OPS | **[core]** |
| Structured Unified Logging | Categories: lifecycle, preflight/exec, transport, pairing/trust, update, managed policy. Metadata + durations only — never env vars, creds, keys, terminal I/O, full cert material | OPS | **[core]** |
| Local diagnostics + redacted support bundle | Versions, CLI path, preflight results, effective non-secret settings **and their source**, listener status, cert expiry + short fingerprints. Manifest preview, user-chosen path, **no upload, no server-side ID** | OPS, SET | **[core]** |
| **No telemetry, no account, no activation — stated in the UI** | Zero analytics/crash upload/phone-home; an About/Privacy view listing every network destination | SET, OPS, UX | **[core]** |
| Notification categories | Container exited unexpectedly, pull/build finished, host offline; errors not disableable, zero promotional categories. **Researchers disagree on phase — see §6 Q6** | SET, UX | **[core]** or **[later]** |
| `config.toml` view | Phase 1 read-only via `system property list --format json`; validated round-tripping editor later | SET | **[core]** read-only |

---

## 3. Phase 2 — Host mode + client mode over mTLS

| Feature | One-line | From | Rec |
|---|---|---|---|
| **Full Phase-1 parity over the wire with zero new feature code** | The acceptance criterion for Phase 2 — and only true under the args-over-wire design (§6 Q1) | RUN | **[core]** |
| Add-host sheet with two peer paths | Bonjour list **and** manual hostname/IP+port side by side — manual is mandatory per DECISIONS.md, not a fallback | UX, SET | **[core]** |
| **Pairing ceremony, two-sided** | Side-by-side fingerprints with fixed roles, hostname/IP under each, SHA-256 in grouped hex + a word/emoji form, explicit Trust/Cancel; **changed cert shows old vs new and defaults to Cancel**; approval required at *both* ends; attempts expire and are rate-limited | UX, OPS | **[core]** |
| Pending-peer "waiting room" | Bonjour-discovered but un-allowlisted Macs queue for approval instead of being silently rejected | RUN, OPS | **[core]** |
| Discovery is never identity | Bonjour supplies name/address/port only; both paths enter the same trust flow; fail closed on every TLS verification path | OPS | **[core]** |
| mTLS with unique per-device Keychain identities | Non-exportable key where practical, no plaintext/server-only fallback; **validate the cert, then separately authorize against the fingerprint allowlist** | OPS | **[core]** |
| Certificate lifecycle fields from day one | issuer/source (self-generated/manual/managed), fingerprint, created, expires, last-seen; warn before expiry; design for overlapping pins; manual re-pair is the v1 recovery path | OPS | **[core]** |
| Immediate local revocation | Removing a peer updates the allowlist atomically, **closes live connections**, rejects resumption, leaves an audit entry. "Block" ≠ "forget address" | OPS | **[core]** |
| Protocol/version handshake | Exchange app version, wire min/max, capabilities, runtime version, mode before accepting mutations; unknown ops fail closed. **Required before Phase 5 can stagger updates** | OPS | **[core]** |
| **Wire extensions designed now, used later** | client→host `.stdin` frames + `.resize(rows:cols:)` for exec/`registry login`, and a binary frame type for `cp`/`save`/`export`. **⚠ `wire-protocol.md` is currently one-way** — design in Phase 2 so Phase 4 isn't a protocol break across a deployed fleet | RUN, OPS | **[core]** |
| Host-mode UI is deliberately minimal | Status window + own menu-bar item: listen address/port, Bonjour on/off, allowlist count, last client, recent commands, big "Stop accepting connections". **No container management UI in host mode** | UX | **[core]** |
| Mode switch (Client/Host/Both) in Settings | A `UserDefaults` key from day one so Phase 6 can force it; plain-language consequence + confirm; **never switchable remotely** | SET, UX | **[core]** |
| Host-mode settings | `listenPort`, Bonjour advertise + service name, require-mTLS (shown, locked on), identity Keychain label, generate/regenerate identity, show own fingerprint | SET | **[core]** |
| Per-host connection states with distinct visuals | online / connecting / unreachable / **untrusted** / version-mismatch — "untrusted" must not look like "offline", they need different fixes | UX, OPS | **[core]** |
| Per-host settings get/set messages | Two Wire messages over the typed registry; cheapest if the message types land here even if the UI is Phase 3 | SET | **[core]** |
| Per-peer role / subcommand restriction | A read-only observer role is the useful version; defer until there's a second controller | RUN, OPS | **[later]** |
| Connection tuning prefs | Connect timeout, retry/backoff, keepalive — sensible defaults first, expose only if they matter | SET | **[later]** |

---

## 4. Phase 3 — Fleet view

| Feature | One-line | From | Rec |
|---|---|---|---|
| **Aggregate container list with a Host column, groupable by host** | The thing no comparable does — Docker Desktop has no multi-host GUI, Portainer drills into one environment at a time | RUN, UX | **[core]** |
| Fleet sidebar + clickable rollup | "All hosts" aggregate row, per-host status dot + count, offline dimmed; header "6 hosts online · 14 containers" **filters when clicked**, not decoration | UX | **[core]** |
| Host detail page | `system version`, `system df`, service status, container/image counts, last-seen, fingerprint, per-host actions (prune, restart service) | UX, RUN | **[core]** |
| **Staleness indicator** | Last-successful-poll timestamp per host; show cached data greyed rather than empty. Macs sleep | RUN | **[core]** |
| **Adaptive polling** | Fast when frontmost, ~30 s menu-bar-only, exponential backoff for down hosts, pause when hidden. With no event stream this is a feature, not an optimisation | RUN, UX, SET | **[core]** |
| **Trust-management view (not just a host list)** | Connection state shown separately from trust state; role, identity source, short fingerprint, expiry, last auth, last address, versions, managed flag; actions: compare, approve, revoke, rotate/re-pair, export public identity, audit | OPS, UX, SET | **[core]** |
| Host groups / tags + per-host identity | Nickname, colour/tag, role, notes, include-in-aggregate, per-host poll interval. Cheap now, expensive to retrofit; maps onto Phase 6 managed settings. **UX rated the display-name half `[later]`** | RUN, SET | **[core]** |
| Fleet defaults + per-host override | One template with explicit per-host deviations shown as overridden — the Jamf/Kandji shape, not 8 settings screens | SET | **[core]** |
| **Version-skew warning** | One `system version` per host already gives it; classic fleet failure mode | RUN | **[core]** |
| Fan-out: pull an image to selected/all hosts | The highest-value fleet verb; per-host progress and partial-failure reporting | RUN | **[core]** |
| Cross-host bulk actions + `host:`-scoped ⌘K | Always with an explicit per-host preview of what will be affected | RUN, UX | **[core]** |
| Import/export host list + settings | JSON of the typed registry + inventory. **Two hard rules: never export private keys; export fingerprints as fingerprints so the importer still makes its own trust decision** | SET, OPS | **[core]** |
| Menu-bar/Dock badge on fleet trouble | Badge when a host is unreachable or a container is crash-looping | UX | **[core]** |
| Config drift view | Merged `system property list --format json` from every host in one table, differing keys highlighted — read-only first. Structurally impossible for Docker Desktop | SET | **[later]** |
| "Where should this run?" host ranking | Suggest the host with the most free CPU/RAM instead of eight stat rows | RUN | **[later]** |
| Fleet image inventory | "Which hosts have `alpine:latest`?" — group aggregate `image list` by digest | RUN | **[later]** |
| Image transfer host→host | `save`/`load` over the wire; avoids a registry on a LAN-only fleet. Needs binary framing | RUN | **[later]** |
| Push settings to all hosts | Powerful and dangerous; needs a diff preview + per-host confirm. Arguably better served by the Phase 6 profile | SET | **[later]** |
| Compose file → pre-filled run sheet | Import as form pre-fill, never as an execution engine | RUN | **[later]** |
| Dock menu mirroring popover essentials | HIG recommends it precisely because the extra can vanish into the notch | UX | **[later]** |
| Editable `config.toml` (local) | Validated TOML round-trip (not regeneration), "requires service restart" banner + restart button | SET | **[later]** |

---

## 5. Phases 4–6

### Phase 4 — Live streaming + exec

| Feature | One-line | From | Rec |
|---|---|---|---|
| Live log + stats streaming over the persistent connection | Sampling-interval setting, pause when hidden, **only stream what's on screen** — 8 hosts × per-container streams is a self-inflicted DoS | UX, RUN, SET | **[core]** |
| Real sparklines + Stats tab (Swift Charts) | Only now, because only now is the data real | UX, RUN | **[core]** |
| **Interactive exec terminal with a real PTY** | `exec -i -t`; the most-wanted tab in every comparable — **ship a real PTY or don't ship the tab**. Security: fresh visible user action, target host+container shown, bounded lifetime/concurrency, no transcript logging by default, dies on revocation | RUN, UX, OPS | **[core]** |
| **Self-implemented restart policy + health checks** | Per-container policy (`no`/`on-failure`/`always`), retries, backoff, health cmd+interval+timeout+threshold, history timeline. **The UI must say when the policy applies** — a policy that silently only runs while the client is open is a trust-destroying lie. **UX rated this `[later]`; see §6 Q3 for where the loop runs** | SET, RUN, UX | **[core]** |
| Log/stats/terminal prefs | Default tail (200), wrap, timestamps, follow-on-open, buffer cap, font size; stats sample interval + SwiftData retention/prune | SET | **[core]** |
| File browser via `exec ls`/`stat` + `cp`, **Reveal in Finder** | 80% of Docker's Files tab at 5% of the cost. **UX says read-only browse+download first; RUN rates the whole thing `[core]`** | RUN, UX | **[core]** read-only first |
| Bind-mount/port editor with a **host-aware path picker** | **The single most likely source of user error in the app**: a laptop file picker selects a path that doesn't exist on the target Mac, and published ports are at the *host's* address, not `localhost` | RUN | **[core]** |
| Activity/history log of every command Flotilla ran, per host | Genuinely useful fleet forensics; SwiftData is already in the stack | RUN, OPS | **[later]** |
| Exec prefs (default shell/user/workdir, "open in Terminal.app") | | SET | **[later]** |

### Phase 5 — Auto-updates

| Feature | One-line | From | Rec |
|---|---|---|---|
| Sparkle 2 with **dual trust** | HTTPS appcast on GitHub releases, `SUPublicEDKey`, Ed25519-sign every artifact **and** require valid Developer ID; signing keys outside the repo; treat Sparkle security updates as release blockers | OPS, SET | **[core]** |
| Separate check / download / install-restart controls | First-run consent (never silently phone home), release notes in the dialog, "Check for Updates…" in popover + Settings. Use Sparkle's own `UserDefaults` keys so Phase 6 can lock them for free | SET, UX, OPS | **[core]** |
| **Host-safe update interruption point** | Stop accepting new remote mutations, let bounded requests finish, persist no partial trust change, then relaunch and re-run preflight. Never kill a host mid-mutation | OPS | **[core]** |
| Release gates | Archive → sign → notarize → staple → verify → clean-install + N-1 upgrade test → delta-fallback test → appcast URL/signature/version-monotonicity check → smoke both modes. **Don't publish the appcast before the asset and notarization verify** | OPS | **[core]** |
| **Canary + rollback runbook** | Update the client and one noncritical host, verify, then host by host. Keep the previous notarized artifact; **Sparkle 2 has no downgrade — rollback is an explicit reinstall**. Always preserve an alternate path to every Mac | OPS | **[core]** |
| "What's New" sheet after update | With a dismissal that actually sticks | UX | **[later]** |
| Fleet-wide `container` CLI upgrade | Fixes version skew — but "user authorization, never silent" on a *remote* Mac means a prompt **on that Mac**, not a click on the client. Design that before promising it | RUN, OPS | **[later]** |
| Phased rollout groups / channels / deltas | Seven-group rollout is for public populations; eight named Macs want a named canary | OPS | **[later]** |

### Phase 6 — Jamf / configuration profiles

| Feature | One-line | From | Rec |
|---|---|---|---|
| Two payload tiers: `defaults` + `locked` | Suggest vs. enforce, with the same mechanism; on macOS the locked tier is nearly free via `/Library/Managed Preferences` | SET, OPS | **[core]** |
| Managed key set | `mode`, `listenPort`, `bonjourEnabled`, `trustAnchorFingerprints`, `peerAllowlist`, `identityKeychainLabel`, Sparkle keys, diagnostics policy, min accepted client version, fleet defaults | SET, OPS | **[core]** |
| Managed values visibly locked | Greyed + lock glyph + "Managed by configuration profile"; a diagnostics page showing **effective value, source, validation errors, last reload**; pairing/cert UI hidden when identity arrives by profile | UX, SET, OPS | **[core]** |
| Unique MDM-delivered identity per Mac | Per-device passphrase-protected PKCS#12 (or SCEP when renewal infra exists); select by cert attribute, not an editable path; **never one shared `.p12` scoped to a group** | OPS | **[core]** |
| Reset never touches the managed domain | It can't anyway — but the UI must say so | SET, OPS | **[core]** |
| Prove the profile on a staged smart group | App-before-profile and profile-before-app, renewal overlap, removal, reboot, locked screen, logout, segmented network, revoked controller; profile removal → safe "managed identity unavailable", not a self-generated replacement | OPS | **[core]** |
| Jamf owns app updates on managed minis | Managed setting disables Sparkle there; two update authorities create races. Confirms DECISIONS.md | OPS | **[core]** |
| Export a profile from current settings | Configure one mini by hand, deploy to seven — and testable long before Jamf exists | SET | **[later]** |
| Hide (not just disable) managed-away UI | On a mini pinned to host mode, hide the client UI rather than showing a dead sidebar | SET | **[later]** |
| Managed trust rotation + revocation distribution | Overlapping anchors, activate new, verify, remove old; profile generation numbers; reject policy rollback | OPS | **[later]** |
| Opt-in crash reporting | Only if local Apple crash reports prove insufficient; scrubbed, previewable, MDM-forcible-off | OPS | **[later]** |

---

## 6. Open questions — ✅ ALL RESOLVED 2026-07-27

> Every question below was answered by the user on 2026-07-27 and is now recorded in
> `DECISIONS.md` ("Proposal review — settled 2026-07-27"). Kept here for the reasoning
> and the alternatives considered — **DECISIONS.md is the authority, not this section.**
>
> | Q | Decision |
> |---|---|
> | Q1 Wire shape | **Middle path** — args passthrough + subcommand allowlist + schema validation |
> | Q2 Default view | **Table**, card grid demoted to a toggle |
> | Q3 Host mode | **Stateful** — persisted policy store |
> | Q4 Managed settings | **Two-tier now** — `defaults` + `locked` |
> | Q5 Phase 1 scope | **Approved as consolidated** (the fuller Phase 1) |
> | Q6 Notifications | **Phase 1**, full per-category toggles |
> | Q7 `config.toml` | Read P1 · edit locally P3 · remote only if needed |
> | Q8 Bundle ID | `dev.melonfleet.Flotilla` |
> | Q9 App Sandbox | **No App Sandbox for v1** (still notarized + hardened runtime) |


**Q1 — Wire shape: CLI-args passthrough, or typed bounded operations?**
RUN argues the args-over-wire design is an "unusually strong property": every Phase-1 feature
becomes a fleet feature in Phase 2 at zero marginal cost, and the command string doubles as the
audit log. OPS argues the opposite: "the host must expose typed, bounded `container`
operations — not a generic remote shell", validating operation, argument schema, frame length,
concurrency and deadline before spawning anything, and explicitly **"do not expose an arbitrary
command string in Phases 2–3."** This is the single highest-consequence open item: it decides
Phase 2's cost, whether Phase-1 parity is free, and how exec is gated in Phase 4. A middle path
exists (args passthrough constrained by an `args[0]` subcommand allowlist + schema validation),
but it needs your call, not ours.

**Q2 — Table or the card grid as the default container view?**
UX recommends a table (running-first, sortable, multi-select) with the mockup's cards demoted to
a toggle, on the grounds that cards stop scaling around 20 rows. That contradicts the premise of
`design/dashboard-mockup.html`, which is your design. Needs sign-off either way.

**Q3 — Does host mode become stateful?**
Two features push it there: restart/health (RUN: the loop must run on the **host peer**, or
closing the laptop stops restarting containers on the minis) and per-host settings get/set.
Both mean host mode needs a persisted policy store — a real expansion of PLAN.md's "host mode is
the same binary running headless-ish", which currently just executes CLI args. Accept the
expansion, or accept that restart policies only apply while the client is connected (and say so
in the UI).

**Q4 — Confirm the two-tier `defaults`/`locked` managed model now?**
`reference/jamf-config-profile.md` currently says "if a managed value is present it wins". SET
recommends upgrading to defaults-seed + locked-override **before Phase 2 writes the settings
accessors**, because retrofitting precedence means rewriting every accessor. Cheap now,
expensive later — but it is a real scope addition to Phase 1.

**Q5 — Is §2 the Phase 1 you want?**
As consolidated, Phase 1 includes volumes, networks, the settings registry, the security
baseline, diagnostics and the support bundle — more than PLAN.md's Phase 1 line
("container grid, images list, run/stop/restart/remove, logs view"). Approve as-is, or cut to
the PLAN.md line and push the rest to Phase 1.5.

**Q6 — Notifications in Phase 1 or Phase 3?**
SET rates per-category notification toggles `[core]` in Phase 1; UX designs the categories in
Phase 2 and ships them in Phase 3. PLAN.md doesn't mention notifications at all.

**Q7 — Should Flotilla ever *write* `~/.config/container/config.toml`?**
Reading is unambiguously good. Writing means owning a file another tool owns, on a machine you
may not be sitting at, with a service restart to apply. SET's recommendation: read in Phase 1,
edit locally in Phase 3, edit remotely only if it proves necessary.

**Q8 — Bundle ID / preference domain. ✅ DECIDED (2026-07-27): `dev.melonfleet.Flotilla`.**
`dev.melonfleet.*` is the canonical reverse-DNS root for the whole suite (per
`design/brand/BRAND.md`, which supersedes any earlier `com.melonfleet.*`), matching the
owned `melonfleet.dev` domain. Recorded in `DECISIONS.md`; governs the UserDefaults /
managed-preference domain, Keychain services, launchd labels, pkg identifiers, Sparkle
keys and Jamf payloads. No longer open.

**Q9 — Confirm "no App Sandbox for v1" as a recorded decision?**
OPS makes the case (we execute an external CLI and listen for connections; a useful sandbox
needs brittle exceptions). DECISIONS.md is currently silent. Worth recording explicitly so it
isn't re-litigated — including that notarization ≠ sandboxing ≠ hardened runtime.

---

## 7. Contradictions and disagreements — flagged, not resolved

### 7.1 Where research pushes against a settled doc

| Where | What it says now | What the research proposes | Source |
|---|---|---|---|
| `reference/wire-protocol.md` | One-way: `WireRequest` carries args once; `WireResponse` flows host→client only | Needs client→host `.stdin`/`.resize` frames (exec, `registry login --password-stdin`) and a binary frame type (`cp`, `save`/`load`, `export` — base64 is fine for config files, bad for a 400 MB tar). **Extension, not contradiction — but must be designed in Phase 2** | RUN, OPS |
| `reference/jamf-config-profile.md` | "If a managed value is present it wins" | Two tiers: `defaults` (seed, user may change) + `locked` (always wins). See Q4 | SET, OPS |
| PLAN.md — "host mode … headless-ish, executes CLI args" | Stateless executor | Restart/health loop and per-host settings both live on the host peer → persisted state. See Q3 | RUN, SET |
| PLAN.md — "menu-bar app" | Menu-bar extra is the entry point | The extra can be hidden by System Settings, swallowed by the notch, or removed (which auto-terminates an `LSUIElement` app). The window must be reachable without it; needs a "Show in: Menu bar / Dock / Both" setting | UX |
| Apple HIG | "Display a menu — not a popover — when people click your menu bar extra" | `MenuBarExtra(.window)`, using HIG's own "unless too complex for a menu" escape clause; mitigated by allowing no text entry, dialogs or destructive confirmations in the popover | UX |
| `design/dashboard-mockup.html` | Card grid with sparklines | Table by default, cards as a toggle; sparklines deferred to Phase 4 (Phase 1 shows numeric CPU% from a two-sample delta, because `stats` returns cumulative µs). See Q2 | UX, RUN |
| `design/branding.md` | Pink = brand/selection, green = healthy | Then pink **cannot** double as the error colour — needs an explicit semantic red/orange assignment | UX |
| DECISIONS.md (silent) | No sandbox position recorded | "No App Sandbox for v1", hardened runtime + least entitlements instead. See Q9 | OPS |
| DECISIONS.md — guided `.pkg` install, "user authorization, never silent" | Written for the local Mac | On a **remote** host, honouring it means an authorization prompt on *that* Mac — which nobody is sitting at. Fleet CLI upgrade needs a design answer before it's promised | RUN, OPS |

**No researcher proposed anything DECISIONS.md rejects** — no ssh, no gRPC, no Kubernetes, no
Containerization-framework linking, no Electron, no silent privileged install.

### 7.2 Where two researchers disagree

| Topic | Positions | Where it's resolved |
|---|---|---|
| **Wire protocol shape** | RUN: args passthrough is the whole value proposition · OPS: typed bounded operations, never an arbitrary command string in Phases 2–3 | Q1 — the big one |
| **Notifications** | SET: `[core]` Phase 1 · UX: design Phase 2, ship Phase 3 | Q6 |
| **Restart/health** | RUN + SET: `[core]` Phase 4, loop on the host peer · UX: `[later]` | Q3 |
| **Files tab** | RUN: `[core]` Phase 4, browse + upload · UX: `[later]`, read-only browse + download first | Listed as `[core]` read-only-first above; upload deferred |
| **Host tags/groups** | RUN: `[core]` Phase 3 ("cheap now, expensive later") · UX: `[later]` (custom display names) | Listed `[core]`; RUN's retrofit-cost argument is the stronger one |
| **Volumes / networks** | RUN: `[core]` Phase 1, create+delete is ~free · UX: they'd blow the 3–4 nav-item cap; put them on one "System" page | Both, merged: build the features, hide them behind one nav item |
| **⌘K palette** | RUN: `[core]` Phase 1 · UX: slip to Phase 3 if Phase 1 gets tight | Listed `[core]`, first thing to cut |
| **Per-container domain names** | RUN: `[skip]` but "revisit" — `system dns create` exists · UX: `[skip]`, and any web index contradicts mTLS-only | Skip; revisit only as an in-app fleet view |

---

## 8. Deliberately NOT doing

**Because the runtime can't back it** (`container` 1.1.0 has no such command — drawing the
button would be a lie):

- **`pause`/`resume`, `rename`, live resource `update`, `top`, `commit`, `diff`** — no backing commands.
- **Compose as an execution engine** (stacks, `up`/`down`, dependency ordering) — no compose, no
  dependency model. Compose-file *import into a pre-filled run sheet* is the honest version, Phase 3/4.
- **Event-driven UI** — no `docker events` analogue. Everything is polling; that's why polling
  discipline is a Phase 3 `[core]` feature.
- **Docker/OrbStack-style CPU/RAM/disk resource sliders** — there is **no shared host VM to size**.
  One micro-VM per container; the real knobs are `[container] cpus/memory` defaults + per-run flags.
  Faking the pane invents a control that does nothing.
- **File-sharing / bind-mount configuration pane** — no VirtioFS-vs-FUSE choice exists; mounts are
  per-run, so they belong in the run sheet.
- **Finder-mounted container filesystems** (OrbStack's `~/OrbStack/…`) — needs a FileProvider/FUSE-class
  extension, and makes no sense for a *remote* Mac. `cp` + Reveal in Finder is 80% at 5% of the cost.

**Because it's the wrong product**:

- **Accounts, sign-in, licensing, activation, SSO, seat reporting, cloud control plane** — personal
  and non-commercial. Docker's reappearing "You can do more when you sign in" banner is the single
  most-complained-about thing in the entire survey.
- **Telemetry / analytics of any kind** — the correct amount for a personal app is zero, and saying
  so in the Settings UI is itself a feature. (Docker and Podman both default it **on**.)
- **Image vulnerability scanning** (Trivy/Scout) — needs a bundled scanner + vuln DB + updates.
  Enormous, and orthogonal to a fleet manager.
- **Extensions / plugin marketplace, Dev Environments, Learning Center, embedded AI assistant,
  in-app notification centre** — product-growth surfaces, not features.
- **Docker Hub browse/search in-app** — a "pull by ref" field covers the real need.
- **Kubernetes / any orchestrator view** — already settled in DECISIONS.md; `container` is not a CRI runtime.
- **Multi-host stack deployment** (Portainer Edge Stacks) — the fan-out primitives (pull image, run
  template on N hosts) give most of the value without an orchestrator.
- **Customizable/reorderable nav tabs** — a symptom of IA sprawl. Cap nav at 3–4 items instead.
- **In-app theme/accent picker** — macOS owns this; a custom picker is a permanent maintenance tax.
- **A web dashboard / `orb.local` equivalent** — would mean an HTTP server on every host,
  contradicting the mTLS-only transport.
- **"Mini player" compact window** (Tailscale) — our popover already is that.

**Because it's disproportionate security machinery for eight personal Macs**:

- **Distributed trust authority / shared CA / Tailnet-Lock clone** — mutual leaf pinning plus
  explicit bilateral approval is proportionate. Revisit only with multiple administrators or
  internet-wide management.
- **A custom root daemon or privileged updater** — Developer ID + Sparkle + Apple's authorized
  package installer cover it; a privileged helper would materially enlarge the attack surface.
- **Automatic fleet-wide update, and automatic downgrade** — a bad binary could remove the only
  management path. Named-host canaries, one at a time. Sparkle 2 has no downgrade semantics.
- **A general ACL language / fine-grained roles** — start with `client-controller` and `host`;
  defer roles until there's a second real controller.
- **Shell-completion install / PATH management** — the `container` pkg owns `/usr/local/bin`.
- **Beta/experimental features tab** — a beta tab inside a pre-1.0 app is noise.
- **`container machine` management** — read-only `machine list` in host detail is the ceiling.
- **USB passthrough, sound** — irrelevant to headless fleet Macs.
