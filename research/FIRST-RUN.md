# Iris report: the first run

*Iris, 2026-10-13, for the first-run redesign (TODO ▸ Soon). Research, not a decision.*

## Summary

Flotilla should use a short, polished **four-to-five-step setup assistant**, followed by the existing Overview “Get started” card. It should not be a tutorial.

First run should decide only things that affect safety, networking, prerequisites, appearance, Greta, or disclosed outbound connections. Adding hosts, running containers, notifications, and advanced preferences should happen in context afterward. This follows Apple’s guidance: onboarding should be brief, interactive, and optional where possible; customization and permissions should be deferred unless essential to operation. [Apple HIG: Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding)

The strongest design is a roughly **720 × 600 pt standalone setup window** with the Flotilla icon and seascape, a stable footer containing Back/Continue, and “Step 2 of 5.” Finish into a role-aware checklist on Overview.

## What good Mac apps do

Counts below are user-visible stages, not every click; managed deployments and existing accounts shorten them.

| Pattern | Examples | Typical first run |
|---|---|---|
| Immediate utility | OrbStack, Xcode | **0–1 setup screens.** OrbStack advertises being ready out of the box; Xcode presents one welcome window with Create, Clone, and Open, deferring project-specific questions to the chosen action. [OrbStack](https://docs.orbstack.dev/quick-start), [Xcode](https://developer.apple.com/tutorials/develop-in-swift/create-a-project) |
| Prerequisite assistant | Docker Desktop, Tailscale | **1–3 stages.** Docker asks for its licence, then uses an unprivileged default; privileged configuration is now deferred to Advanced settings. Tailscale asks for the VPN configuration and SSO because neither can be avoided. [Docker installation](https://docs.docker.com/desktop/setup/install/mac-install/), [Tailscale installation](https://tailscale.com/docs/install/mac) |
| Action-oriented onboarding | Raycast, 1Password | Usually **3–5 short stages:** establish the essential shortcut/account, import if useful, request only a permission needed for the next action, then let the user work. Raycast’s current migration can be skipped and rerun later; 1Password puts Accessibility setup in its Autofill task rather than in generic first run. [Raycast v2](https://www.raycast.com/new), [1Password Autofill](https://support.1password.com/mac-universal-autofill/) |
| Workspace setup | Linear | Roughly **3–5 account/workspace questions**, while product education lives in a demo workspace, start guide, and optional live onboarding—not a desktop tour. [Linear start guide](https://linear.app/docs/start-guide) |
| Brand-heavy walkthrough | Arc’s legacy Mac onboarding | About **5–7 pages:** account, import, colour, blocker/default-browser choices and miniature interactions. It is memorable but long; import remains available later. This is appropriate for replacing a browser’s mental model, not a technical control panel. [Arc import](https://resources.arc.net/hc/en-us/articles/19335089616791-Import-Bookmarks-Logins-History-Extensions-from-Your-Previous-Browser) |

The common rule is more important than the exact count: ask unavoidable questions up front, give safe defaults, and move instruction beside the feature. Multi-page flows use Back plus a short step label or dots; optional imports and tours get Skip/Not now. System authorization sheets are treated as conditional tasks, not progress steps.

## What Flotilla should ask

The repository already has the right foundation: Admin is the safe preselection, and role determines whether the app listens on the network ([current onboarding](Sources/Flotilla/OnboardingView.swift:12)). “Both” should not return: it is retired and decoded as Admin ([RunMode](Sources/FlotillaCore/Settings/SettingsTypes.swift:105)).

| Item | Treatment | Reason/default |
|---|---|---|
| Role | **Ask, required** | Admin preselected. It determines network exposure and the remainder of setup. Respect managed settings and explain that the organisation chose them. |
| `container` runtime | **Ask conditionally** | If absent, offer installation checked by default, with Not now. Name the download, Apple signature check, size, and forthcoming Installer password request. Never start privileged installation silently; this is already Q39’s rule. |
| Appearance and themes | **Ask** | Auto preselected; show the existing miniature-window picker. Save both light and dark choices, defaulting to Cantaloupe and Flesh. Auto switches between them ([theme specification](design/THEMES.md:97)). |
| Greta | **Ask with On preselected** | Say “Runs on this Mac; nothing is sent away. Greta reads and drafts—she never runs anything.” Save enabled intent only after this disclosure. |
| Add first host / pair with admin | **Later, in context** | Requires another machine, address or trust decision. Put the next action in the Overview checklist; do not block first run. |
| Automatic Flotilla update checks | **Ask explicitly; Admin only** | Preselected on. Say it checks Flotilla’s GitHub release feed. Host-only Macs are updated by their admin. |
| Suggestions daily check | **Ask explicitly** | Preselected on, separate checkbox: contacts `raw.githubusercontent.com` daily, sends no identifier or Mac data, and accepts only signed libraries. The present settled behavior is documented in Q54 ([decision](DECISIONS.md:2313)). |
| Notifications | **Ask later** | Request after the user enables monitoring or when Flotilla first has a meaningful stopped/unhealthy-container alert. Apple explicitly recommends contextual rather than launch-time notification requests. [Notification authorization](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications) |
| Launch at login | **Ask only for Host** | A host must be reachable after login: show a checked checkbox on its setup page. For Admin, retain the current off default and leave it in Settings. Registration remains subject to user approval. [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice/register%28%29) |
| Menu bar / Dock | **Default silently** | Keep both: Dock on, menu bar always present. Briefly mention the menu-bar status item on Finish; presentation is not worth a first-run question. These are already the stored defaults ([settings](Sources/FlotillaCore/Settings/SettingsRegistry.swift:56)). |
| Local Network | **Host: request during setup. Admin: later when Add Host is used** | It is essential to the chosen Host role but not to an isolated Admin. Use a one-button pre-alert explaining discovery, management, and published ports. Apple says permission should normally be requested at feature use, except when required for the app’s function. [Apple HIG: Privacy](https://developer.apple.com/design/human-interface-guidelines/privacy/) |

### Local Network’s special problem

An app cannot call a normal `requestAuthorization` API. It triggers the system alert by performing a genuine local-network operation; macOS then records the answer. Before doing so, Flotilla should show “Allow Local Network so an admin Mac can find and manage this host, and so published container ports can accept connections,” followed by one button, **Request Access**. Start the real Bonjour listener/browser immediately afterward.

Include `NSLocalNetworkUsageDescription` and the Bonjour service types in `NSBonjourServices`; neither key currently appears in this repository. Apple requires the usage description for direct, multicast, and Bonjour traffic. [NSLocalNetworkUsageDescription](https://developer.apple.com/documentation/BundleResources/Information-Property-List/NSLocalNetworkUsageDescription)

There is also no general public API for reading authorization state. Treat prolonged `.waiting`/policy-denied networking as a probable permission problem, show repair instructions for System Settings → Privacy & Security → Local Network, and retry after the app becomes active. Do not mark the step successful merely because the prompt was triggered. MDM cannot grant this per-user permission. [TN3179](https://developer.apple.com/documentation/Technotes/tn3179-understanding-local-network-privacy)

## Greta on first run

`SystemLanguageModel.default.availability` distinguishes:

- `.available`: model use can begin.
- `.appleIntelligenceNotEnabled`: the user has disabled Apple Intelligence.
- `.deviceNotEligible`: the system says this Mac is unsupported.
- `.modelNotReady`: models are unavailable because they may be downloading or for another system reason.
- An unknown future unavailable reason.

It does **not** supply download percentage, ETA, the precise eligibility failure, or proof that the machine is a VM. Locale support is a separate `supportsLocale` check. Apple says model downloads depend on network, battery, and system load. [Foundation Models availability](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel), [modelNotReady](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum/unavailablereason/modelnotready)

Recommended wording:

- **Available:** “Greta is ready. She runs on this Mac, answers questions, and prepares drafts for you to review.”
- **Apple Intelligence off:** “Greta needs Apple Intelligence, which is currently off. Turn it on in System Settings; Flotilla will notice when it becomes available.” Button: **Open Apple Intelligence Settings**.
- **Device ineligible:** “Greta isn’t available on this Mac. Flotilla otherwise works normally, and it won’t send your questions or fleet information to a cloud model.”
- **Model not ready:** “Apple’s on-device model isn’t ready yet. macOS prepares it automatically; Greta will become available when it is ready.”
- **Unknown:** “Greta isn’t available right now. Try again later.”

On macOS 26 the working deep link is:

`x-apple.systempreferences:com.apple.Siri-Settings.extension`

It is an undocumented System Settings URL, so use it opportunistically and retain textual navigation plus a generic System Settings fallback. Apple’s supported instructions name the Apple Intelligence & Siri pane. [Apple Support](https://support.apple.com/en-sg/guide/mac-help/mchl46361784/mac), [documented pane identifier reference](https://github.com/bvanpeski/SystemPreferences/blob/main/macos_preferencepanes-Ventura.md)

The current implementation overstates two cases by asserting VM/Apple-silicon causes and definite downloading ([Greta.swift](Sources/Flotilla/Greta.swift:113)); use the narrower wording above.

## Tutorial and visual design

Do not build a forced walkthrough. Technical users want the runtime working and the interface available; passive explanations will not survive until their first host or container.

Instead, evolve the existing seascape “Get started” card ([OverviewView](Sources/Flotilla/OverviewView.swift:380)) into a checklist that reflects role and actual state. Completing Run, Add/Pair Host, or Try a Suggestion should teach through the real form. Use at most two dismissible coach marks: the first time the menu-bar item becomes useful, and the first Greta opening.

For polish:

- Use a dedicated **720 × 600 pt** setup window, stable across steps—not the current narrow 460-pt sheet.
- First screen: 96–112 pt layered app icon, “Welcome to Flotilla,” one sentence (“Run containers here and manage them across your Macs”), and the role cards below.
- Put the faint seascape across the lower third; avoid both a large icon and a second competing logo. A small melonfleet wordmark can sit above the title.
- Give Admin and Host illustrated cards with two benefits and one consequence, especially “accepts connections from an admin Mac.”
- Use live miniature window sketches for themes; avoid colour-name-only radio buttons.
- Footer: **Back**, “Step n of 5,” **Continue**. Use **Not now** only for optional runtime installation or unavailable Greta—not a global Skip that silently chooses a network role.
- Finish with one calm status summary, not confetti: Runtime ready, Greta ready/waiting, Local Network allowed/needs attention.

## Recommended flow

1. **Welcome & Role:** choose Admin or Host; save `mode`; Admin defaults selected, and Host visibly opts into launch at login, checked by default.
2. **Make It Yours:** choose Auto/Light/Dark plus light and dark theme sketches; save `appearance`, `lightTheme`, and `darkTheme`; defaults Auto, Cantaloupe, Flesh.
3. **Greta:** explain on-device, read-and-draft-only behavior and show live availability; save `gretaEnabled = true` when accepted, with Flower as the silent avatar default.
4. **Prepare This Mac:** conditionally install Apple `container` and, for Host, enable the Helper and trigger Local Network access; each privileged or system permission action remains explicit.
5. **Online Checks:** independently choose Flotilla update checks and daily signed Suggestions updates; both are preselected, their GitHub contact is stated, and Host omits the app-update option.
6. **Finish → Overview:** save completion and open the role-aware checklist—Admin gets Run a Container, Add Host, and Try Suggestions; Host gets Pair with Admin, verify reachability/published ports, and Run a Container.
