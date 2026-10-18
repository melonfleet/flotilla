# Iris: Flotilla right-pane review

**Recommendation: keep the visual language and the Mail-style split. Improve what each page prioritises, how it behaves when narrow, and how clearly it distinguishes current facts from missing data.**

The strongest changes are:

- Make an existing group open as an operational overview, with **Edit** as an explicit action.
- Introduce shared layouts for headers, facts and cards that remain readable at **360pt**.
- Fix misleading data presentation before polishing spacing: remote container metrics and port links, unknown relationship inventories, inconsistent volume capacity, and indefinite loading text.

The existing neutral cards, restrained palette and native controls are a good foundation. Large areas of unused background are acceptable; truncated useful information beside oversized metadata cards is the problem.

**Evidence and limits.** I opened all nine screenshots and reviewed their page code and shared components. Containers shows the group editor, so the individual container review is code-based. Clusters also has **no selected item** in its screenshot; its detail review is code-based. Hosts shows a group heading, so its detail review is likewise code-based. Findings at 360pt come from layout constraints, not a running-app test. Keyboard, VoiceOver and dark-mode behaviour still need interactive verification. Competitor references below verify documented behaviour, rather than exact current pixel layouts.

Line references refer to this mirror.

## 1. Containers

**What works:** The group editor makes service startup order explicit, while individual containers already have useful operational tabs and real resource measurements.

1. **Make metrics and published addresses belong unmistakably to the selected Mac.**  
   In [ContainerDetailView.swift:180](Sources/Flotilla/ContainerDetailView.swift:180), `resourceCard` reads metrics and history by bare container ID; those accessors use the local sampler. `portRow`, at line 248, also constructs `localhost` addresses regardless of `host`. Gate these surfaces by host now: show “Live usage unavailable for this Mac” where peer telemetry is unavailable, and label ports as published **on the named Mac**. Offer remote Copy/Open only when an appropriate reachable address is known. Otherwise a remote page can show a local namesake’s usage or open the wrong service. **Code-path finding; not reproduced interactively.**

2. **Open groups as live summaries, with Edit.**  
   [ContainersView.swift:214](Sources/Flotilla/ContainersView.swift:214) currently opens `GroupFormView` immediately. Add a group overview headed **analytics**, with “0 of 2 services running”, the Mac, network, and the existing lifecycle actions. Show each service’s current state and a link to its container page. Put **Edit…** in the header and reuse the existing draft editor. Save should return to the overview with the group still selected. This makes selecting a group answer “what is happening?” before “what can I change?” It is a deliberate refinement of Q58’s group-as-form choice, while preserving the split and embedded forms.

3. **Put health ahead of metadata, and make both page types adapt.**  
   In [ContainerDetailView.swift:131](Sources/Flotilla/ContainerDetailView.swift:131), surface the existing health result and restart failure beside lifecycle state, before image details. Reuse `ContainerPolicyCard`’s report rather than creating another health rule. Apply the shared one-column layout below 600pt. In [GroupFormView.swift:345](Sources/Flotilla/GroupFormView.swift:345), stack service identity above editing controls at narrow widths; four trailing icons should not squeeze the name and image. Put the redacted command preview behind **Show startup commands**. Preserve the existing named accessibility labels for reordering.

**Borrow, don’t copy:** OrbStack documents group-level Compose actions alongside actions for individual containers, plus direct access to logs, terminals and addresses. Borrow that operational emphasis for group pages. Docker Desktop similarly makes inspection, logs and resource statistics distinct destinations. Flotilla already has those destinations; it needs clearer entry points. [OrbStack menu-bar actions](https://docs.orbstack.dev/menu-bar), [Docker Desktop container details](https://docs.docker.com/desktop/use-desktop/container/).

## 2. Images

**What works:** The page is compact and understandable, and “Used by” provides a useful route from an image to its containers.

1. **Promote usage, and distinguish “unused” from “inventory unavailable”.**  
   In [ImageDetailView.swift:92](Sources/Flotilla/ImageDetailView.swift:92), a missing peer snapshot becomes `[]`, producing “No containers use this image. Prune would remove it.” Reference-string matching alone also deserves caution before making a prune guarantee. Carry inventory availability and freshness into this card. Show a neutral header summary such as “Referenced by 1 container”, and use “Container inventory unavailable” when appropriate. Only make a removal claim from authoritative eligibility data. This supports the decision people come here to make without overstating certainty.

2. **Make references and digests easy to take away.**  
   [ImageDetailView.swift:154](Sources/Flotilla/ImageDetailView.swift:154) limits every value to one line. The screenshot’s digest is already shortened despite the surrounding space. Add visible, keyboard-reachable **Copy reference** and **Copy digest** actions; allow an expanded full digest or wrapping value below its label. At 360pt, stack long technical values vertically. A tooltip and selectable truncated text are useful supplements, but should not be the main way to retrieve an identifier.

3. **Reduce duplicate metadata and empty-history weight.**  
   In [ImageDetailView.swift:67](Sources/Flotilla/ImageDetailView.swift:67), repository, tag and reference repeat identity already present in the header. Keep the complete reference once, then prioritise usage, platform and size. Let short cards use their natural height. Replace the empty events paragraph with “No events recorded this session”, keeping the history limitation in help or a disclosure. Label the two tabs **Overview** and **Inspect** using the shared tab improvement below.

**Borrow, don’t copy:** Docker Desktop documents explicit In use/Unused states, copy affordances for identifiers, and navigation to containers using an image. Borrow the combination of usage and identity actions; retain Flotilla’s quieter page rather than adding vulnerability panels without corresponding data. [Docker Desktop Images view](https://docs.docker.com/desktop/use-desktop/images/).

## 3. Registries

**What works:** Provider-specific token guidance and the distinction between required, optional and unnecessary authentication are unusually helpful.

1. **Show registry details first; open credentials through Sign In.**  
   [RegistriesView.swift:266](Sources/Flotilla/RegistriesView.swift:266) opens the manage form directly, and [RegistryFormView.swift:323](Sources/Flotilla/RegistryFormView.swift:323) always includes the credential section. Start with server, authentication state and a clear **Sign In…** or **Switch Account…** button. That action opens the existing embedded credential flow and focuses Username. Successful sign-in should return to the same selected registry. **Do not require a generic Edit step before signing in:** authentication is the task; Edit belongs only to genuinely editable registry metadata.

2. **Expose default behaviour and credential scope beside status.**  
   The selected Docker Hub row says “default”, but the page makes that consequential fact hard to find. Add “Default for unqualified image names” and “Credentials on this Mac” to the summary, with **Set as Default** when applicable. Reuse the existing action in [RegistriesView.swift:529](Sources/Flotilla/RegistriesView.swift:529). Keep **Remove from List** distinct from **Sign Out**, including in accessible names. This matters in a fleet app: a registry entry, stored credentials and connectivity are different facts. Do not imply that a stored credential is a successful live connection test.

3. **Remove repetition from the manage page and tighten the active form.**  
   [RegistryFormView.swift:476](Sources/Flotilla/RegistryFormView.swift:476) repeats name, server and status under “In the table as”; the screenshot also repeats “Optional” across several blocks. Keep that preview for **Add**, remove it for **Manage**, and consolidate the authentication explanation into one sentence. Preserve the provider guidance and token link inside the active sign-in flow. Retain `FormField`’s label pairing, associate failures with the credential controls, and make Escape return to the summary through the existing guard.

**Borrow, don’t copy:** System Settings’ Internet Accounts page distinguishes the selected account’s settings from the flow for adding an account, with a separate Details action for descriptive metadata. Borrow that distinction between viewing identity and entering credentials, rather than its exact layout. [Apple Internet Accounts settings](https://support.apple.com/en-au/guide/mac-help/mh35705/mac).

## 4. Volumes

**What works:** The page correctly treats size as capacity and exposes the backing source without inventing a usage gauge.

1. **Add “Used by” before low-level storage metadata.**  
   [VolumeDetailView.swift:73](Sources/Flotilla/VolumeDetailView.swift:73) cannot currently answer the most useful question before deletion: which containers depend on this volume? Derive relationships from the selected Mac’s container `configuration.mounts`, using the existing `volumeName` accessor. Show container name, state, mount destination and read-only/read-write mode, with links to container pages. Include stopped containers. Distinguish a successfully checked empty set from an unavailable or incomplete inventory.

2. **Use one capacity formatter everywhere.**  
   [VolumeDetailView.swift:129](Sources/Flotilla/VolumeDetailView.swift:129) uses `.memory`; [VolumesView.swift:1052](Sources/Flotilla/VolumesView.swift:1052) uses `.file`. This produces the visible **1 GB versus 1.07 GB** disagreement. Use the same disk-capacity formatter in list, header and detail, consistent with the project’s disk-size convention. Make exact bytes available in help or the expanded value. Keep the label **Capacity**, and state “Usage not reported” if needed.

3. **Turn the source path into a useful secondary detail.**  
   In [VolumeDetailView.swift:95](Sources/Flotilla/VolumeDetailView.swift:95), show **Backing file**, with Copy and a full-path disclosure. Offer **Reveal in Finder** only for an accessible local source; a remote path should identify its Mac. Remove the same long path from the header subtitle in `VolumesView.subtitle`. At 360pt it consumes scarce identity space without becoming readable. Use natural-height cards and the shared stacked fact layout.

**Borrow, don’t copy:** Docker Desktop’s volume detail explicitly lists consuming containers and mount targets. OrbStack provides a direct folder action for volume files. Borrow dependency visibility and a useful file affordance, while making clear that Flotilla’s backing `.img` file is not a browsable mounted volume. [Docker Desktop Volumes view](https://docs.docker.com/desktop/use-desktop/volumes/), [OrbStack native file access](https://docs.orbstack.dev/features/native-files).

## 5. Networks

**What works:** Addressing has its own card, attached containers are navigable, and built-in networks already receive special treatment.

1. **Distinguish configured membership from active attachment.**  
   [NetworkDetailView.swift:86](Sources/Flotilla/NetworkDetailView.swift:86) finds containers only through `status.networks`. Also consult configured network attachments, so a stopped container can appear as **Configured; stopped**, without an invented current address. Separate that from a running attachment. A missing peer snapshot must produce “Container inventory unavailable”, rather than “No containers are attached”. Present name, state and address as two lines when narrow, with a combined accessible description.

2. **Make complete addresses the first useful facts.**  
   [NetworkDetailView.swift:75](Sources/Flotilla/NetworkDetailView.swift:75) mixes IPv4, IPv6 and creation date, while its row helper truncates everything. Group **IPv4 subnet / Gateway** and **IPv6 subnet**, add Copy actions, and allow long IPv6 values below their labels. Put creation date with metadata. At 360pt, a single Addressing card should retain complete values. Use “Not reported” for missing addressing data unless the model positively establishes “Not configured”.

3. **Demote implementation facts and remove false visual weight.**  
   In [NetworkDetailView.swift:62](Sources/Flotilla/NetworkDetailView.swift:62), lead with addressing and container relationships; move plugin and built-in details into a compact **Properties** card. Replace “Built in: No” with an explanatory note only when the built-in restriction matters. Remove forced card height where content is short and compact the empty events state. Keep status language factual: configured addressing is not evidence of a healthy network.

**Borrow, don’t copy:** System Settings separates IPv4 and IPv6 configuration and uses explicit address, subnet and router fields. Borrow that grouping and precision, while retaining Flotilla’s container-relationship card. This is a structural precedent, not a claim that Apple provides an equivalent container-network page. [Apple TCP/IP settings](https://support.apple.com/en-ie/guide/mac-help/mh141292/27/mac/27).

## 6. DNS

**What works:** The page explains container naming in plain language, and existing actions already preserve the restart and administrator-confirmation flow.

1. **Separate resolver installation from container naming.**  
   [DNSFormView.swift:274](Sources/Flotilla/DNSFormView.swift:274) presents one composite status. Show two explicit facts: **Resolver on this Mac: Installed** and **Container naming: Enabled**, using `DNSCopy`’s existing state distinctions. Label `<container>.flotilla` **Name pattern**, and show `web.flotilla` as a clearly marked example. Put the owning Mac beside these facts for remote domains. This makes partial setup understandable and avoids treating a configuration checkmark as proof that a DNS lookup succeeded.

2. **Present existing domains as details, without the form footer.**  
   Existing-domain `manageFields` is already mostly read-only. Give it the shared page layout instead of the create-form scaffold. Remove “In the table as” from [DNSFormView.swift:341](Sources/Flotilla/DNSFormView.swift:341), remove **Done**, and keep one Delete affordance in the standard header position. Move the resolver-file path into **Details**, with Copy. **A generic Edit button adds little here:** the current domain properties are not editable fields; Use, Stop Using, Set Up and Delete are explicit operations.

3. **Put the consequence beside the naming action.**  
   At [DNSFormView.swift:302](Sources/Flotilla/DNSFormView.swift:302), add a short explanation before **Use for Containers…** or **Stop Using…**: changing the container domain restarts the runtime and stops running containers; new naming applies to containers created afterwards. Preserve the existing confirmation. Stack the blocked reason and buttons at 360pt rather than putting them in one `HStack`. Keep the domain and action consequence in the VoiceOver reading order before the control.

**Borrow, don’t copy:** OrbStack documents concrete container and Compose service names, making the resulting address easy to understand. Borrow that concrete-example treatment, while exposing Flotilla’s explicit setup steps and different runtime behaviour. [OrbStack container domain names](https://docs.orbstack.dev/docker/domains).

## 7. Machines

**What works:** The page shows state immediately, has consistent operational tabs, and correctly explains that saved settings may apply only after restart.

1. **Stop truncating the home-directory access explanation.**  
   The screenshot visibly clips the most consequential sentence on the page. In [MachineDetailView.swift:142](Sources/Flotilla/MachineDetailView.swift:142), make the value simply **Read-write** and put “Your home directory is writable inside this VM” beneath it as wrapping explanatory text. Alternatively, use a full-width **Mac file access** card. Keep this explanation visible at 360pt and readable as one labelled accessibility element. A two-line, middle-truncated fact row is unsuitable for it.

2. **Distinguish configured resources from live use, and make the next action obvious.**  
   Rename the Resources card to **Configured resources** in [MachineDetailView.swift:125](Sources/Flotilla/MachineDetailView.swift:125), with **Disk capacity** rather than Disk. Keep the shared adaptive grid and move long image identity into secondary details. Near the stopped state, offer **Start and Open Terminal**, reusing the behaviour already implemented by `MachineShellTab`. Replace unexplained Started/IP dashes with contextual wording such as “No current address reported”; do not infer “Never started” merely from a missing timestamp.

3. **End loading explicitly when inspect fails.**  
   The task at [MachineDetailView.swift:103](Sources/Flotilla/MachineDetailView.swift:103) receives an optional result, while the Image card shows “Loading the full record…” whenever image data is absent. Track loading, loaded and failed states separately. On failure, retain list-derived facts and show “Additional details unavailable” with **Retry**. A successfully loaded record with no image should say “Not reported”. Announce completion or failure without moving keyboard focus.

**Borrow, don’t copy:** OrbStack’s documented machine actions put opening a terminal and accessing files close to the machine itself. Borrow the direct terminal action. Its filesystem integration is a separate capability and should not be implied by Flotilla’s home-mount setting. [OrbStack machine actions](https://docs.orbstack.dev/menu-bar), [OrbStack Linux machines](https://docs.orbstack.dev/machines/).

## 8. Clusters

**What works:** The code deliberately limits the page to reported facts, avoiding invented node counts, versions and usage measurements.

*The screenshot verifies the empty-selection state, not the selected cluster layout.*

1. **Make “Reach it” the main task, with actions beside the instructions.**  
   Move the card in [ClusterDetailView.swift:33](Sources/Flotilla/ClusterDetailView.swift:33) immediately below the state summary. Put **Write Kubeconfig…** there for local clusters, reusing the existing action, plus **Copy kubectl command** with a useful example such as `kubectl --context … get nodes`. Do not make people follow prose directing them to a row menu. For remote clusters, identify where the command runs and what endpoint was reported without implying this Mac has a route to it.

2. **Separate cluster state from report freshness and recovery.**  
   [ClusterDetailView.swift:22](Sources/Flotilla/ClusterDetailView.swift:22) puts stale-host wording into the Mac fact. Promote this to “Last reported running — Mac not answering”, with the snapshot time. Keep **Recreate…** clearly named and described as deletion followed by creation, using the existing confirmation in [ClustersView.swift:553](Sources/Flotilla/ClustersView.swift:553). It must not visually read as an ordinary restart.

3. **Keep the small page compact and carry its experimental context when expanded.**  
   Combine name, role and configured resources into one natural-height properties card, using the common 12pt page inset rather than the current 16pt. Use contextual missing-endpoint wording when stopped, and stack long API/command values at 360pt. Carry a small **Experimental** explanation onto the detail page so widening it does not remove all context. Move the printed-table parsing explanation into help; it need not dominate the working page.

**Borrow, don’t copy:** OrbStack makes Kubernetes context selection an explicit user-facing action. Borrow that emphasis on reaching the intended cluster. Its documented Start/Stop/Restart capabilities are not a precedent for buttons Apple’s CLI cannot support here. [OrbStack Kubernetes](https://docs.orbstack.dev/kubernetes/).

## 9. Hosts

**What works:** The code already prioritises actionable notices, supports the same page structure for local and trusted remote Macs, and explains runtime-control consequences.

*The screenshot verifies the empty page beneath a group selection; these recommendations concern `HostDetailView`.*

1. **Lead with connection, runtime and timestamped usage.**  
   In [HostDetailView.swift:217](Sources/Flotilla/HostDetailView.swift:217), keep Needs attention first, then put connection state, runtime state, last check-in and usage together before hardware and versions. `Usage now` currently follows five overview cards. Rename it **Latest reported usage** and show the report’s age; stale readings should not look current. Replace groups of dashes with one explanation when a host is unavailable or lacks reporting support. Use the shared one-column layout at 360pt.

2. **Make nine destinations understandable without memorising icons.**  
   [HostDetailView.swift:118](Sources/Flotilla/HostDetailView.swift:118) adds SSH, Screen Sharing and Files to six existing tabs. Use the shared labelled navigation, with a compact Sections menu when necessary. A labelled **Connect** menu can select the three existing access pages and include their On/Off/Unknown states. Preserve the current rule that selecting a destination opens its page; it must not immediately launch an external application. Put editable grouping metadata with other configuration rather than among operational overview facts.

3. **Make inventory links explicitly scoped to this host.**  
   In [HostDetailView.swift:667](Sources/Flotilla/HostDetailView.swift:667), count links call only `go(section)`. Pass the host as part of navigation so the destination reliably shows that Mac’s inventory, regardless of an earlier section filter. Make the whole labelled row the link, and give it an accessible name such as “Show 13 containers on minimac”; a button named only “13” is weak. Rename **Running here** to **Resources on this Mac**, because images, volumes and networks are inventory, not running processes.

**Borrow, don’t copy:** System Settings treats Remote Login, Screen Sharing and File Sharing as distinct services. Borrow their explicit names and separate states rather than hiding them behind unfamiliar glyphs. [Apple sharing services](https://support.apple.com/en-euro/guide/mac-help/mchlp1125/27/mac/27).

**Orchard verification:** Its current official quick start documents fleet orchestration through CLI/API. I could not verify a current first-party host-detail GUI, so I am not attributing a visual pattern to Orchard. [Orchard quick start](https://tart.run/orchard/quick-start/).

## Shared page template

The sections already share `DetailCard`; their larger drift is in page structure and interaction. Add a thin shared page shell, rather than another card style.

| Layer | Common behaviour |
|---|---|
| Identity | Resource name, textual state, owning Mac where relevant, and freshness when data is reported remotely. |
| Actions | Relevant primary action, existing overflow and Delete/Remove, then previous/next and expand. |
| Navigation | Labelled sections where they fit; a native compact alternative when they do not. No tabs for single-purpose pages. |
| Attention | Actionable failure, unhealthy state or stale-data explanation before ordinary facts. |
| Main content | Operational state, usage or relationships first; identity and implementation metadata second. |
| Editing | Explicit entry into a draft. Save/Cancel returns to the selected resource’s overview. |
| History | Recorded events beneath useful content; a quiet empty state when none exist. |

**Keep `SplitPanes`’ selection, expansion, remembered widths and form guard.** In particular, do not solve narrow pages by increasing the minimum window width or abandoning Q58.

### Layout and density

- Replace the fixed two-column grids with a shared **maximum-two-column** layout: two columns when the page has roughly 600pt available; one below that. Measure the page, not the window. At 360pt, current grids leave roughly 160pt per card before internal padding.
- Extract a shared fact row: horizontal for short values; label above value for long references, paths, addresses and explanations. Allow copying without depending on hover.
- Keep `DetailCard`’s neutral surface, 10pt corners and outside heading. Let short cards follow their content; equalise neighbouring cards only when useful.
- Give headers a two-row compact arrangement. At narrow widths, put identity on its own line and controls beneath it. This preserves the name and the existing header actions.
- Keep useful whitespace below a short page. Do not fill it with repeated identity, empty events paragraphs or unsupported measurements.

Relevant foundations: [DetailCard.swift:20](Sources/Flotilla/DetailCard.swift:20), [FormHeader.swift:57](Sources/Flotilla/FormHeader.swift:57), [SplitPanes.swift:68](Sources/Flotilla/SplitPanes.swift:68).

### Status and missing values

Use a small shared vocabulary instead of making every missing value an em dash:

| Meaning | Presentation |
|---|---|
| Request in progress | “Loading…” |
| Successful response omitted a fact | “Not reported” |
| Optional configuration absent | “Not set” or a specific equivalent |
| Runtime-dependent fact unavailable | Explain the dependency, for example “Available while running” |
| Previously reported remote data | Value plus “Last reported…” and timestamp |
| Relationship inventory unavailable | “Inventory unavailable”; do not report zero |
| Known empty result | Specific wording such as “No containers use this volume” |

Empty history should say **“No events recorded this session”**. “Nothing has changed” claims more than the recorder knows.

Use existing `Theme` semantic colours for application-assigned status. Keep native controls, system selection/focus and links as specified in `THEMES.md`; add no decorative colours or tinted resource cards. Text and symbols must carry status alongside colour. The documented 2.94:1 success mark on Honeydew also deserves a palette-level contrast decision, rather than page-specific colour substitutions.

### Keyboard and VoiceOver

There is already good work to preserve: `DetailStepper` has named controls and position values; `PageTabs` supplies labels and selection traits; `FormField` pairs labels with controls.

Build on it:

- Use native labelled segmented controls for two-tab pages. For larger sets, provide a labelled compact section selector. Apply shortcuts consistently and scope them to the active page; avoid collisions with nested selectors.
- Preserve **⌘[ / ⌘]** for stepping. Do not take text fields’ ⌘↑ / ⌘↓.
- Give card titles heading traits and fact rows a coherent label/value reading order. Preserve independently reachable links and Copy buttons.
- Keep keyboard focus stable during polling. After editing, restore focus to Edit or the initiating action; after changing selection, verify that VoiceOver announces the new resource.
- Verify visible focus on the custom plain tab buttons and Copy controls. Tooltips are additional help, not the sole label or retrieval mechanism.

The shared implementation point is [PageTabs.swift:47](Sources/Flotilla/PageTabs.swift:47). Activity Monitor is a useful precedent for selecting a process and inspecting its measured state without entering an editor. Borrow that viewing posture, not its separate inspector window. [Apple Activity Monitor process information](https://support.apple.com/en-ie/guide/activity-monitor/actmntr1001/mac).

## Implementation order

Effort is relative: **Small** means a contained presentation or state correction; **Medium** means shared-view work or a new overview flow.

| Order | Work | Effort | Value |
|---|---|---|---|
| 1 | Gate remote container metrics/addresses; distinguish missing relationship inventories from empty results. | Small–Medium | Prevents misleading information and actions. |
| 2 | Unify volume capacity; untruncate home access; end failed machine loading; shorten empty-history text. | Small | Visible, concrete improvements with little structural work. |
| 3 | Build adaptive fact rows, card grids and compact headers; apply them across existing detail pages. | Medium | Makes the whole right pane usable at 360pt. |
| 4 | Improve shared tab labels, keyboard consistency and accessibility semantics. | Small–Medium | One implementation benefits every tabbed page. |
| 5 | Simplify registry and DNS manage pages; retain focused credential and change flows. | Medium | Removes repetition and unnecessary form chrome. |
| 6 | Add the group operational overview with explicit Edit. | Medium | Fixes the largest mismatch between selection and page purpose. |
| 7 | Add volume consumers, configured network membership, and cluster connection actions. | Medium | Makes the pages better places to complete work. |
| 8 | Reorder Hosts and make inventory navigation host-specific. | Medium | Improves fleet diagnosis and movement between sections. |

Before accepting the shared layout, check it at the supplied **1333×854** window and at a **360pt page**, with long names, unavailable peers, empty data and errors. Exercise keyboard-only navigation and VoiceOver, including editing followed by stepping to another item. Check the existing light and dark theme variants. These checks remain unverified by this static review.
