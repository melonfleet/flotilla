# Iris report: what Greta and Flotilla can connect to on the Mac

*Iris, 2026-10-13, at Kamal's request. Research, not a decision.*

# Mac integrations and container-maintenance routines

## Summary

Flotilla should treat macOS integration as a reminder, discovery, and approval layer—not as a new automation engine.

The best near-term opportunities are scheduled local notifications, read-only/draft-only App Intents, and opt-in Calendar/Reminders handoff. macOS 26’s Shortcuts automations make weekly maintenance triggers practical, but any intent that updates, prunes, restarts, installs, or otherwise mutates the fleet must open Flotilla’s review UI rather than execute unattended.

Widgets, Focus filters, Contacts, and Time Machine integration offer much less value. Background read-only monitoring is valuable, but scheduled registry, update, or vulnerability checks introduce outbound traffic and must be explicitly enabled.

These conclusions preserve [Q52–Q54](DECISIONS.md:2197), the [vulnerability-scanning constraints](research/VULNERABILITY-SCANNING.md), and the [MCP design](research/MCP.md).

## 1. What Flotilla can reach on macOS 26/27

| Surface | Capability and permission | Fit with Q52 |
|---|---|---|
| **EventKit: Calendar** | Create scheduled, alarmed, and recurring events. Write-only access is available; reading requires full access—there is no read-only tier. These produce separate Calendar TCC prompts using `NSCalendarsWriteOnlyAccessUsageDescription` or `NSCalendarsFullAccessUsageDescription`. Sandboxed/hardened apps also need the Calendar entitlement. [Event-store access](https://developer.apple.com/documentation/eventkit/accessing-the-event-store), [recurrence](https://developer.apple.com/documentation/eventkit/creating-a-recurring-event) | Good if Greta creates a typed draft, Flotilla shows title/time/recurrence/calendar, and the user confirms the save. Greta must not call `save` herself. Prefer write-only access. |
| **EventKit: Reminders** | Create, read, complete, edit, alarm, and recur. Unfortunately, even creation requires **full Reminders access** and its TCC prompt (`NSRemindersFullAccessUsageDescription`). Calendar and Reminders alarms are delivered by those apps. [Personal-data permissions](https://developer.apple.com/documentation/technologyoverviews/personal-data), [alarms](https://developer.apple.com/documentation/EventKit/setting-an-alarm) | Useful, but the broad permission is disproportionate. Ask only when the user first confirms “Add to Reminders”; never merely because Greta mentioned one. |
| **App Intents / Shortcuts** | Flotilla can publish typed actions and entities to Shortcuts and Spotlight. macOS 26 added Personal Automations triggered by time, file/folder, network, power, app, and Focus events, including unattended time-of-day runs. App Intents has no blanket TCC prompt; an intent inherits prompts from protected APIs it uses. Background-capable intents may run in an extension. [App Intents](https://developer.apple.com/documentation/appintents/getting-started-with-the-app-intents-framework), [Mac automations](https://support.apple.com/en-ie/125148) | Publish only reads, navigation, or form creation: “Show hosts needing attention”, “Open host X”, “Prepare image updates”, “Draft container from recipe”. Do not publish silent `Update`, `Prune`, `Install`, or `Restart` intents. |
| **App Shortcuts** | Apple’s current HIG explicitly says App Shortcuts—the preconfigured Siri phrases—aren’t supported on macOS. Ordinary App Intent actions are supported in the Mac Shortcuts app. Users can build and name a shortcut, then invoke that shortcut through Siri. [App Shortcuts HIG](https://developer.apple.com/design/human-interface-guidelines/app-shortcuts) | Do not promise zero-setup Siri phrases. Support user-built shortcuts; expose two to five excellent actions if Apple later enables App Shortcuts on Mac. |
| **Focus filters** | A `SetFocusFilterIntent` can change Flotilla configuration or filter notifications when a Focus changes. There is no TCC alert; the user explicitly adds the filter in Focus settings. Background handling uses an App Intents extension. [Focus API](https://developer.apple.com/documentation/appintents/focus) | Low-value but compatible: “During Production Focus, show only production-host notices.” It must not start maintenance automatically. |
| **WidgetKit** | Native Mac widgets can live on the desktop and in Notification Centre. No privacy prompt; the user chooses to install one. Updates are timeline-based and opportunistic, not continuous monitoring. [WidgetKit](https://developer.apple.com/documentation/WidgetKit/) | A read-only “Fleet attention” or “Hosts offline” widget fits. Widget buttons should open the relevant Flotilla review page. |
| **Local notifications** | Calendar and repeating time triggers work even when Flotilla is not running. Alerts/sounds/badges require the Notifications prompt; Apple recommends asking in context. Delivery is not guaranteed to be exact. [Scheduling](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app), [authorization](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications) | Excellent fit and largely already present under Q48. A notification action should say “Review updates…” rather than execute them. |
| **Core Spotlight** | Flotilla can index hosts, containers, images, recipes, and documentation in an app-private, on-device index. No TCC prompt; users can disable app search in Siri & Spotlight settings. Apple says indexed data remains on-device and is not synchronized to Apple. macOS 27 can also expose an app index to Foundation Models through `CoreSpotlightSource`. [Core Spotlight](https://developer.apple.com/documentation/CoreSpotlight), [indexing](https://developer.apple.com/documentation/CoreSpotlight/adding-your-app-s-content-to-spotlight-indexes) | Good for recipes/docs and opted-in inventory. Avoid indexing logs, environment values, image secrets, fingerprints, or sensitive host names by default. |
| **Share sheet** | `ShareLink`/`NSSharingServicePicker` can share a redacted report, support bundle, configuration, or Greta-written summary. No Flotilla TCC prompt; the user explicitly chooses a destination, which may itself use a network service. [ShareLink](https://developer.apple.com/documentation/swiftui/sharelink) | Strong fit: Greta drafts a sanitized summary and the user deliberately shares it. Logs remain excluded in Greta 1.5. |
| **Contacts** | Read/write access triggers the Contacts prompt, with limited or full access. [Contacts access](https://developer.apple.com/documentation/contacts/accessing-the-contact-store) | No credible container-management use justifies this permission. Omit it. |
| **Time Machine** | Ordinary Flotilla files can be backed up normally. Apple exposes APIs to **exclude** recreatable files, and MDM can configure Time Machine, but there is no supported app-consistency/pre-backup hook for quiescing container volumes. Broad file access may require Full Disk Access or admin authority. [Backup exclusion API](https://developer.apple.com/documentation/foundation/urlresourcekey/isexcludedfrombackupkey), [Time Machine settings](https://support.apple.com/en-euro/guide/mac-help/mh14037/27/mac/27) | Mark caches/scanner DBs as excludable. Save user-approved, consistent volume exports into an ordinary chosen folder; do not present live VM-disk Time Machine copies as reliable volume backups. |
| **`launchd` / `SMAppService`** | A bundled login item or LaunchAgent can keep read-only checks and Q53 policies running. This is not TCC, but registration is subject to Login Items approval and may remain `requiresApproval`. A daemon additionally needs admin approval. [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice), [registration](https://developer.apple.com/documentation/servicemanagement/smappservice/register%28%29) | Flotilla already uses this. Appropriate for deterministic policy code, never for letting Greta run later. |
| **Menu bar** | `MenuBarExtra` supplies persistent status and common controls without a permission prompt. [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra) | Already the correct home for “Next maintenance”, overdue backups, and attention counts. Actions open the app. |
| **Foundation Models tools** | A `Tool` can call arbitrary app code, including EventKit; Apple’s WWDC25 example directly queried Contacts and Calendar and received the normal underlying permission prompts. Tools may also cause side effects. [Tool protocol](https://developer.apple.com/documentation/foundationmodels/tool), [WWDC25 example](https://developer.apple.com/videos/play/wwdc2025/301/) | There is no automatic “make all App Intents Greta tools” bridge. A tool could technically invoke shared code or an `AppIntent`, but Apple presents Foundation Models agents and App Intents/Siri as separate integration routes. Keep Greta’s tools physically read-only; turn her output into draft data outside the tool layer. Apple’s current security guidance emphasizes confirmation checkpoints for agentic actions. [WWDC26 security guidance](https://developer.apple.com/videos/play/wwdc2026/347/) |

## 2. What container users actually schedule

Desktop GUIs mainly provide immediate controls; users move recurring work into the engine, cron/systemd, CI, GitOps, or calendars:

- **Image and base-image updates:** Watchtower polls on a schedule and can update/recreate containers or operate monitor-only. Renovate and Dependabot update Dockerfiles, Compose files, Kubernetes manifests, tags, and digests through scheduled pull requests; CI performs the rebuild and test. [Watchtower modes](https://watchtower.nickfedor.com/v1.19.0/configuration/container-selection/), [Renovate Dockerfiles](https://docs.renovatebot.com/modules/manager/dockerfile/), [Dependabot scheduling](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-options-reference)
- **Docker Desktop:** provides update notifications, optional background downloads/component updates, manual image/Scout workflows, and—now—paid scheduled volume exports. It does not supply a general maintenance-window scheduler for prune/rebuild/redeploy. Docker Scout retired its own CVE notifications in 2026 and directs users to CLI or CI policy checks. [Desktop settings](https://docs.docker.com/desktop/settings-and-maintenance/settings/), [scheduled volume exports](https://docs.docker.com/desktop/use-desktop/volumes/), [Scout retirements](https://docs.docker.com/scout/release-notes/platform/)
- **OrbStack:** auto-updates itself, automatically removes unused build cache, exposes manual compressed volume export/import, and otherwise relies on Docker-compatible tools. [Volumes](https://docs.orbstack.dev/docker/file-sharing), [image cache](https://docs.orbstack.dev/docker/images)
- **Podman Desktop:** offers manual prune and provider/app/extension updates. Podman’s actual recurring auto-update mechanism is Linux systemd/Quadlet: its timer runs daily, pulls images, and restarts units—not a Mac-native Desktop scheduler. [Podman auto-update](https://docs.podman.io/en/latest/markdown/podman-auto-update.1.html), [Desktop resource management](https://podman-desktop.io/tutorial/managing-your-application-resources)
- **Portainer:** is the exception: GitOps polling/webhooks redeploy stacks; Business Edge Agent updates can be scheduled; beta Edge Jobs write cron entries on hosts and can run backups or arbitrary scripts. Portainer itself warns that Edge Jobs are powerful and dangerous. Its own backup does not include managed containers or volumes. [GitOps updates](https://docs.portainer.io/user/kubernetes/applications/manifest/create), [Edge Jobs](https://docs.portainer.io/user/edge/jobs), [backup scope](https://docs.portainer.io/faqs/getting-started/what-does-portainers-backup-include)
- **Rancher Desktop:** offers manual VM snapshots, application-update prompts, and explicit Kubernetes version selection; it is not the Rancher fleet-management product. [Snapshots](https://docs.rancherdesktop.io/1.23/ui/snapshots/), [Kubernetes versions](https://docs.rancherdesktop.io/ui/preferences/kubernetes/)

Consequently, disk pruning, volume backups, secret/certificate rotation, log review, maintenance windows, and vulnerability rescans are commonly cron/CI/Kubernetes CronJob/external-monitoring tasks. Runtime health checks and restart policies are the notable continuous engine-owned routines.

## 3. Routine-to-macOS matches

Legend: **Offline** works from existing local data; **Permission** adds a new macOS permission; **Background** needs Flotilla or its agent running; **Network** adds scheduled outbound traffic.

| Routine | Concrete Flotilla feature | Mark |
|---|---|---|
| Patch/update images | Weekly registry-drift check creates one notice; “Review updates…” opens a digest-by-digest replacement form. | Background, Network |
| Rebuild on base update | “Prepare rebuild for image X” App Intent opens Build with the known Dockerfile/context and changed base digest; CI remains responsible where the source is remote. | Offline for preparation; Network for discovery |
| Prune disk | Monitor `system df`; after a user-set threshold, notify with a precise prune preview. | Offline, Background |
| Back up volumes | Maintenance plan records destination and freshness; at due time, notify and open a Backup wizard that quiesces only with explicit approval. | Offline, Background; Permission only for Calendar/Reminders |
| Rotate secrets/certificates | Track user-entered expiry metadata—not secret values—and draft a recurring reminder plus affected groups. | Offline; Permission for EventKit |
| Health/restarts | Keep Q53’s deterministic host-local checks, bounded backoff, history, and notification with reviewed Restart. | Offline, Background |
| Maintenance windows | Greta drafts a recurring Calendar event and optional Reminder listing affected hosts and expected operations. | Permission; no background needed after save |
| Log review | Schedule a prompt to open the existing Logs view with saved host/container/time filters; Greta still receives no logs. | Offline; Background only for anomaly detection |
| Kubernetes upgrades | Detect available versions, then notify; the action opens an upgrade plan with backup and compatibility checklist. | Background, Network |
| Update `container` | Check Apple’s release metadata only when explicitly enabled; notify and launch the existing verified, visible `.pkg` flow. Apple’s own upgrade remains a stopped-runtime installer/script operation. [Apple container upgrade](https://github.com/apple/container#upgrade-or-downgrade) | Background, Network; privileged confirmation mandatory |
| Vulnerability rescan | After an explicitly approved Grype DB update, re-evaluate cached SBOMs locally and notify only on meaningful new fixable critical/KEV findings. | Offline after DB update, Background; Network only for explicit updates |

## 4. Realistic scope

| Rank | Release | Feature | Value / effort / risk |
|---|---|---|---|
| 1 | **1.5** | Maintenance Plans backed by existing local notifications: fixed/recurring reminders that open a reviewed workflow. | High / Low / Low |
| 2 | **1.5** | App Intents for read-only queries, navigation, and draft forms; support macOS 26 Personal Automations. | High / Medium / Medium |
| 3 | **1.5** | Opt-in write-only Calendar export; add Reminders only after explaining that macOS requires full access. | Medium / Low / Privacy risk |
| 4 | **1.5** | Conservative Spotlight indexing of recipes, docs, and opted-in inventory. | Medium / Low / Metadata-leak risk |
| 5 | **2.0** | Background routine evaluator for image drift, disk pressure, backup age, certificate expiry, Kubernetes versions, and scanner freshness. | Very high / High / Network and false-positive risk |
| 6 | **2.0** | Read-only attention widget and optional Focus filter. | Low–medium / Medium / Low |
| Reject | — | Side-effecting Greta tools or unattended Shortcuts for update, prune, restart, installation, secret rotation, or fleet mutation. | Conflicts with Q52 and privileged-action policy |

Scheduled registry/version/DB checks also amend no-phone-home behavior: each destination, cadence, transmitted data, and managed override must be disclosed and enabled in context. Q54’s signed-library exception does not authorize unrelated background traffic. Vulnerability exposure must never feed Q53 health restarts.

## Top 5 recommendations

1. Ship **Maintenance Plans** in 1.5 using scheduled local notifications whose actions open reviewed Flotilla workflows.
2. Add a small **read-only/draft-only App Intents** set: Show Attention, Open Host, Prepare Updates, Draft from Recipe, and Open Logs Review.
3. Offer **write-only Calendar export**, then separately gate Reminders behind its broader full-access prompt.
4. Build a **background hygiene evaluator** for 2.0, but keep every mutation user-confirmed and every scheduled network destination opt-in.
5. Keep **Greta physically read-only**: she may read bounded status and draft maintenance artifacts, but EventKit saves, App Intents, MCP actions, installers, restarts, updates, backups, and prunes remain outside her tool set.
