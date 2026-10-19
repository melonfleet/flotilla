# Tooltip audit: icon-only controls in Flotilla

- **Repo:** `~/Flotilla` at `e68f16c`, scope `Sources/Flotilla/*.swift`.
- **Requested by:** Kamal, 19 October 2026.
- **Read-only:** no source file was changed.

## How it was done

**All 176 files** in `Sources/Flotilla` were read in full: 55,431 lines in eight parallel passes of about 6,900 lines each. One rubric was used throughout.

- **Shared components first.** `IconActionButton`, `ToolbarIconButton`, `ToolbarRefreshButton`, `ToolbarIconMenu`, `RowSortMenu`, `DetailStepper`, `PageTabs`, `RowCheckbox`, `SelectAllCheckbox`, `RowGroupDisclosure`, `RowOverflowLabel`, `ToolbarMenuGlyph`, `CommandPreviewCopyButton` and `FormHeader`/`FormActions` were read and checked once.
- **Then every call site** was checked: its `help:` and `label:` arguments, and whether a `.help` reaches the control.
- **Non-UI files** (the `AppModel*` extensions, stores, probes) were read and are recorded as "no UI".
- **Segmented-picker behaviour was measured, not assumed.** A scratch SwiftUI probe, outside the repo, rendered pickers in an `NSHostingView` on this Mac (macOS 26). It then read `NSSegmentedControl.toolTip(forSegment:)` directly. See §3.

**Headline.** About 213 icon-only controls were found, and 209 have a working tooltip. The coverage is good because almost everything goes through `IconActionButton`, whose `help:` is a required parameter.

- **Four controls have no tooltip.** Two are `⋮` row menus, one is a hand-rolled disclosure caret, and one is the menu-bar status item.
- **About 30 tooltips exist but are empty, stale, wrong or weak.**
- **One SwiftUI trap affects segmented pickers.** No call site trips it today.

---

## 1. Icon-only controls without a tooltip

| file:line | Section / screen | Icon | What it does | What is missing | Suggested tooltip |
|---|---|---|---|---|---|
| `NotificationsView.swift:171` | Notifications, each row's `⋮` (on hover or selection) | `RowOverflowLabel()`: the Unicode ⋮ character, not an SF Symbol | Opens the row's menu (Restore / Dismiss) | No `.help` on the `Menu`. It does have `.accessibilityLabel("More actions for \(notice.title)")` | "More actions for \(notice.title)" |
| `SuggestionsView.swift:227` | Containers ▸ Suggestions, each row's `⋮` | `RowOverflowLabel()` ⋮ | Opens the row's menu (Use… / Use N Suggestions…) | No `.help`. It has an accessibility label, so it is the same omission as the row above | "More actions for \(entry.title)" |
| `TaskDrawer.swift:188` | Tasks drawer, the caret on each task | `chevron.right`, rotated 90° when open | Expands or collapses the task's steps and output | No `.help` of its own. It inherits `.help(secondary)` from the enclosing `HStack` at `:217`, so hovering the caret shows the task's status line, not what the caret does. It has an accessibility label ("Expand \(title)") and a hint | "Show steps and output" / "Hide steps and output" |
| `FlotillaApp.swift:431–436` | Menu bar, Flotilla's status item (`MenuBarExtra` label) | `Image(nsImage: MenuBarIcon.image(…))`, drawn artwork | Opens Flotilla's menu-bar menu | No `.help` and no tooltip. VoiceOver has a name from `MenuBarIcon.accessibilityLabel`. Low priority: a SwiftUI `.help` on a `MenuBarExtra` label may not reach the `NSStatusItem` button, which I did not test, so this may need AppKit once the Xcode project lands | "Flotilla — 3 containers running" (reuse `MenuBarIcon.accessibilityLabel(status)`) |

### Accessibility-only gaps (the tooltip is fine)

| file:line | Screen | Icon | Issue | Suggestion |
|---|---|---|---|---|
| `VolumesView.swift:971–977` | New Volume ▸ Labels / Driver options | `minus.circle` | The tooltip "Remove this entry" is fine. The VoiceOver label is a bare "Remove" on every row of both lists | `accessibilityLabel("Remove \(entry)")` |
| `SettingsView.swift:406` (with `:59`) | Settings ▸ Greta ▸ Look | `GretaAvatarView` picture buttons | Each button has `.help(style.title)`. But `SettingRow` puts `.accessibilityLabel("Greta's look")` on the whole row of buttons, which can override each button's own label. Check with VoiceOver | Don't label the row when its control is a group of buttons |

### Considered and not counted

- **The `Stepper` arrows** in Settings (`SettingsView.swift:367, 371, 565, 568, 580, 583, 604, 637`) and the machine forms (`MachineDetailView.swift:463, 466`, `MachineFormView.swift:186, 197`) have no `.help`. Each sits beside a visible title and value. Add help if you want them covered: "Change how often containers refresh".
- **The New Image Source picker** (`NewImageView.swift:146`) uses `Label`s without `.labelStyle(.iconOnly)`. In the probe, such segments render the **title only**: label "Pull", no image. So it shows words.
- **The Processes tab's Reload** (`ContainerDetailView.swift:523`) is a `Label` that draws its word. Its empty help is listed in §2.

---

## 2. Tooltips that exist but are wrong, stale, empty or weak

### Wrong or stale

| file:line | Current text | Why it's wrong | Suggested |
|---|---|---|---|
| `MachineFormView.swift:290` | ▶ commit labelled "Save" (its tooltip and VoiceOver label) | ▶ means "starts a job that shows in Tasks" (Q65). This one creates and boots a machine; nothing is saved. Q65 also says to keep the old button's exact words, so the two rules conflict here and Kamal should decide | "Create Machine" |
| `NewClusterView.swift:254` | ▶ "Save" | Same: it creates a cluster as a Tasks job | "Create Cluster" |
| `RegistryBrowserView.swift:235` | ▶ "Pull \(ref)…" | The glyph claims a Tasks job, but the button only opens the Pull form with the reference filled in. The text is right; the glyph choice (`.startsJob`) is the question | Keep the words; consider `.keepsChanges`, or a navigation glyph |
| `HostsView.swift:216` (used at `:1049`, `:1159`) | "This Mac is the admin machine — it can't be removed" | False on a Mac in host mode, which also shows Hosts (the + tooltip at `:491` says so) | "This is the Mac you're using — it can't be removed" |
| `ClustersView.swift:505` (row `detailHelp`) | "The API server is reachable on this Mac at the host port" | Wrong for another Mac's cluster, and it covers the whole second line, not just the port | "State, size and API address on \(hostName)" |
| `GroupViews.swift:130` (`GroupState.explanation`, the group dot's tooltip) | "None of these containers exists on this Mac yet…" | A group can live on another Mac | "None of these containers exists yet. Starting the group creates them" |
| `ContainersView.swift:1363` (+ menu label and tooltip) | "Run a container or create a group" | The menu also has **Suggestions…** (`addMenuItems`, `:817–822`) | "Run a container, create a group or use a suggestion" |
| `ContainersView.swift:328` (filter) | "Filter by state or kind" | The popover also filters by host once paired hosts exist (`:357–366`) | "Filter by state, kind or host" |
| `GroupFormView.swift:299` | "New — saved when you press Save" | The commit is a ✓ now (Q65); there is no Save button to press | "New — kept when you save the group" |
| `VolumesView.swift:870` (Size field help) | "…it is what the Size column reports…" | No Size column since Q56; rows say "… capacity" | "…but the list shows it as 512 GB capacity" |
| `FormHeader.swift:189` (`FormActions` ✕) | "Close" | `DetailStepper`'s ✕ says "Close (Esc)", and Escape is bound to this one too (`.cancelAction`). It's the same key, so the tooltip should say it | "Close (Esc)" |

### Plural bugs

| file:line | Current text | Suggested |
|---|---|---|
| `ContainersView.swift:1888` | "Show \(n) containers" reads "Show 1 containers" | Singular when n == 1 |
| `MachinesView.swift:396–402`, `:577` | Bulk Start/Stop/Delete read "Start 1 machines" after a filter | Make the noun follow the count |
| `RegistriesView.swift:251, 259` (VoiceOver labels) | "Sign out of 1 registries" | Make the noun follow the count |
| `DNSView.swift:295` | "Delete 3", with no noun, while the VoiceOver label says "Delete 3 domains" | "Delete 3 domains" (Images already says "Delete 3 images") |

### Empty tooltips: `.help(cond ? text : "")`

These give a tooltip only while the control is **unavailable**, and none while it can be used.

| file:line | Control | Suggested text for the empty branch |
|---|---|---|
| `ContainerDetailView.swift:523` | Processes ▸ Reload | "List the processes again" |
| `DNSFormView.swift:314` | Use for Containers… | "Name new containers under this domain" |
| `MachineDetailView.swift:515` | Apply and Restart | "Save these settings and restart the machine" |
| `HostsView.swift:1159` | Remove… (menu item) | Omit `.help` for other hosts, or "Forget this host" |
| `ClustersView.swift:611` | Load Image… (menu item) | Disabled when stopped with no reason: "Start the cluster to load an image into it" |
| `GroupFormView.swift:221`, `RunSheetView.swift:447` | Network picker | Omit, or "The network the containers join" |
| `HostDetailView.swift:710` | A whole settings row | Omit (see §3: help on an ancestor is a hazard) |
| `HostModePane.swift:161` | Listening-dependent control | Omit, or say what it does |
| `FormHeader.swift:195`, `HelperSettingsSection.swift:22`, `WindowStatusBar.swift:166`, `ResourceCard.swift:85`, `ResourceRow.swift:167`, `NewImageView.swift:332` | `.help(x ?? "")` | Apply `.help` only when there is text |
| `LogsView.swift:561` | `detailHelp: ""` | The log row's message line gets an empty tooltip instead of its own text; pass the text |

### Weak: says the state or repeats the label, not what the control does

| file:line | Current | Suggested |
|---|---|---|
| `LogsView.swift:203` (text at `:291`) | "All sources" / "Showing 3 sources" | "Choose which sources to show — 3 shown" |
| `LogsView.swift:227` (text at `:332`) | "How the feed is shown" / "Showing timestamps" | "Display options — timestamps on" |
| `LogViewer.swift:185` (text at `:209–210`) | "What to show" / "Showing the boot log" | "Log options — boot log" |
| `OverviewView.swift:356`, `:361` | "Previous" / "Next" (VoiceOver labels already say "… notification") | "Previous notification" / "Next notification" |
| `InspectPane.swift:66` | "Reload" | "Reload the inspect output" |
| `HostSettingsTab.swift:74` | "Reload" | "Reload Flotilla's settings" / "Reload the container settings" |
| `FilesTab.swift:141` | "Icons" / "List" / "Columns" | "Show as icons" / "Show as a list" / "Show in columns" |
| `FilesTab.swift:155` | "Group By" (title case; also the VoiceOver label) | "Group files by" |
| `FilesTab.swift:152` (menu item) | "Group by none" | "Don't group" |
| `FormHeader.swift:191` (`FormActions` ⋯) | "More" | "More actions" |
| `FormHeader.swift:271` (`PageHeader` Back) | "Back" | Fine; optionally "Back to the list" |

### Stale on-screen text seen on the way (not tooltips)

- `SuggestionsView.swift:66` (and its docstring at `:13`): "Save runs it; Skip goes on; Cancel stops the rest". Since Q65 these are ▶, Skip inside ⋯, and ✕.
- `MachineDetailView.swift:174`: "Open the Shell tab…". The tab is "Terminal" (`:18`). `Text(verbatim:)` also prints the backticks literally.
- `DNSFormView.swift:375`: "In the table as". DNS has been rows since Q56.
- Stale doc comments:
  - `RegistryBrowserView.swift:7` still says "Cancel and Pull".
  - `NetworksView.swift:744–749` says it is "hosted in its own window".
  - `LogViewer.swift:213` mentions the "Columns popover".
  - `FlotillaApp.swift:579–585` says container detail is a sheet.

---

## 3. Patterns that would fix many sites at once

### a. Replace `RowOverflowLabel` with a menu that requires its label

- **The problem:** `RowOverflowLabel` is only the ⋮ glyph, with no help and no accessibility label. Each of its 17 call sites adds `.help` and `.accessibilityLabel` by hand. Two forgot the `.help` (the first two rows of §1). The same sites also differ on `.menuIndicator(.hidden)`: Notifications and Suggestions lack it.
- **The fix:** a `RowOverflowMenu(label: String, help: String? = nil) { … }` that draws the glyph, applies borderless style, hidden indicator and `fixedSize`, and sets `.help(help ?? label)` plus `.accessibilityLabel(label)`. That is the same contract as `ToolbarIconMenu`. Every ⋮ then gets a tooltip by construction.

### b. A check script, in the style of `check-settings-consumers.sh`

Fail the build on two cases:

- a `Button { … } label: { Image(systemName: …) }`, or a `Menu … label: { RowOverflowLabel() | Image(…) | ToolbarMenuGlyph(…) }`, with no `.help(` within the modifier chain;
- `.help(` whose argument can be `""`.

The hand-rolled controls are the ones that miss:

- the Tasks caret;
- Overview's ‹ › notice stepper (`OverviewView.swift:352–361`), which also wraps around at the ends, unlike `DetailStepper`.

Prove the script works the way `CLAUDE.md` says: delete one `.help` on purpose and watch it fail.

### c. Kill the empty-string idiom

Add `extension View { func help(ifAny text: String?) -> some View }`. It applies `.help` only for non-empty text, which removes about 15 `?? ""` and `: ""` sites. Better still, give the available state a real tooltip: most of these controls currently explain themselves only when you *can't* use them.

### d. Segmented pickers: what SwiftUI actually does (measured on macOS 26)

| Case | Result (`toolTip(forSegment:)`) |
|---|---|
| `.help` on each segment's content (`Image`/`Label` inside the `Picker`), nothing on the `Picker` | **Each segment gets its own tooltip** ✅ |
| Same, plus `.help` on the `Picker` | **Every segment tooltip becomes nil**, including those with their own help |
| Same, plus `.help` on an ancestor (`HStack { Picker }.help(…)`) | **Every segment tooltip becomes nil** |
| `Label(…).labelStyle(.iconOnly)` segment with no `.help` | No tooltip; the title is not used |
| `Label(…)` segment without `.iconOnly` | Renders the **title only** (no image) |

The outer `.help` also never appeared as an AppKit `toolTip` on the control, so I can't confirm it shows over the whole picker either. Hover was not tested, to avoid moving the pointer. The probe read the segmented control's own tooltip table.

**The trap:** per-segment `.help` works, and a single `.help` anywhere above the picker silently removes all of them. That includes a row-level `.help(cond ? … : …)` like the ones in §2c. I measured a non-empty ancestor help; I did not test an empty `.help("")` ancestor.

**Status in the app.** There are three icon segmented pickers, and all are correct today:

- `InspectPane.swift:81`
- `HostSettingsTab.swift:86`
- `LogsView.swift:185`

Each puts `.help` on each segment, and none has a `.help` on the `Picker` or on any ancestor in its own file. The other 11 segmented pickers have text segments.

**Recommended workaround:** a shared `IconSegmentedPicker(items:selection:)`.

- Items are `(tag, title, systemImage, help?)`.
- It draws `Label(title, systemImage:).labelStyle(.iconOnly).help(help ?? title).tag(tag)` per segment.
- Its docstring says *never* to put `.help` on it or its container.
- The check script in (b) can forbid `.help` within a few lines after `.pickerStyle(.segmented)`.

The three pickers above already hand-write exactly this shape. If a future layout must wrap one in a helped container, `PageTabs` is the robust alternative. Its plain `Button` per tab is immune, because each button's own `.help` wins over the ancestor's.

### e. `FormActions` (checked centrally)

- The commit's tooltip is its label plus the `reason`.
- ✕ is "Close".
- ⋯ goes through `ToolbarIconMenu` ("More").
- The working spinner has `workingHelp`.

All four reach their controls. The only problems are wording:

- "Close" omits "(Esc)";
- "More" should be "More actions";
- `Extra.help ?? ""` puts an empty tooltip on menu items;
- the ▶ commits labelled "Save" (§2).

---

## 4. Totals per file

These are icon-only controls as counted at each call site. Shared-component call sites count where they are drawn, and controls repeated per row count once. The counts are approximate (±2 per file) because the eight passes counted in slightly different ways. "Missing" means no tooltip reaches the control; "Wording" counts §2 items, including those on worded controls.

| File | Icon-only | Tooltip OK | Missing | Wording issues |
|---|---:|---:|---:|---:|
| ActivityView.swift | 3 | 3 | 0 | 0 |
| ClustersView.swift | 7 | 7 | 0 | 2 |
| ContainerDetailView.swift | 0 | 0 | 0 | 1 |
| ContainersView.swift | 23 | 23 | 0 | 3 |
| DetailStepper.swift | 4 | 4 | 0 | 0 |
| DNSFormView.swift | 0 | 0 | 0 | 1 (+1 on-screen) |
| DNSView.swift | 5 | 5 | 0 | 1 |
| FilesPresentation.swift | 1 | 1 | 0 | 0 |
| FilesTab.swift | 11 | 11 | 0 | 3 |
| FlotillaApp.swift | 1 | 0 | **1** | 0 |
| FormHeader.swift (PageHeader + FormActions) | 2 (+3 cluster) | 5 | 0 | 4 |
| GretaView.swift | 13 | 13 | 0 | 0 |
| GroupFormView.swift | 7 | 7 | 0 | 2 |
| GroupOverviewView.swift | 2 | 2 | 0 | 0 |
| GroupServicePickerView.swift | 2 | 2 | 0 | 0 |
| GroupViews.swift | 0 | 0 | 0 | 1 |
| HostDetailView.swift | 2 | 2 | 0 | 1 |
| HostGroupViews.swift | 4 | 4 | 0 | 0 |
| HostModePane.swift | 4 | 4 | 0 | 1 |
| HostSettingsTab.swift | 4 | 4 | 0 | 1 |
| HostsView.swift | 7 | 7 | 0 | 2 |
| ImagesView.swift | 9 | 9 | 0 | 0 |
| InspectPane.swift | 4 | 4 | 0 | 1 |
| KeyValueList.swift | 1 | 1 | 0 | 0 |
| LogsView.swift | 11 | 11 | 0 | 3 |
| LogViewer.swift | 5 | 5 | 0 | 1 |
| MachineDetailView.swift | 2 | 2 | 0 | 1 (+1 on-screen) |
| MachineFormView.swift | 0 | 0 | 0 | 1 |
| MachinesView.swift | 13 | 13 | 0 | 1 |
| MainWindowView.swift | 3 | 3 | 0 | 0 |
| NetworksView.swift | 5 | 5 | 0 | 0 |
| NewClusterView.swift | 0 | 0 | 0 | 1 |
| NotificationsView.swift | 3 | 2 | **1** | 0 |
| OverviewView.swift | 4 | 4 | 0 | 2 |
| PageTabs.swift | 1 (per tab) | 1 | 0 | 0 |
| RegistriesView.swift | 7 | 7 | 0 | 1 (VoiceOver plural) |
| RegistryBrowserView.swift | 1 | 1 | 0 | 1 (glyph) |
| ResourceListControls.swift | 1 | 1 | 0 | 0 |
| ResourceRow.swift | 1 | 1 | 0 | 1 |
| RunSheetView.swift | 1 | 1 | 0 | 1 |
| SettingsView.swift | 6 | 6 | 0 | 0 (+1 VoiceOver) |
| SplitPanes.swift | 2 | 2 | 0 | 0 |
| SuggestionsView.swift | 1 | 0 | **1** | 0 (+1 on-screen) |
| TagManagerView.swift | 2 | 2 | 0 | 0 |
| TagPill.swift | 2 | 2 | 0 | 0 |
| TaskDrawer.swift | 7 | 6 | **1** | 0 |
| TerminalTab.swift | 2 | 2 | 0 | 0 |
| ToolbarSearch.swift | 1 | 1 | 0 | 0 |
| VolumesView.swift | 8 | 8 | 0 | 1 (+1 VoiceOver) |
| WindowBar.swift | 4 | 4 | 0 | 0 |
| WindowChromeControls.swift | 4 | 4 | 0 | 0 |
| **Total (51 files with findings or icons)** | **~213** | **~209** | **4** | **~45** |

Minor empty-help sites with no icon controls (one each): `HelperSettingsSection.swift`, `NewImageView.swift`, `ResourceCard.swift`, `WindowStatusBar.swift`.

**The other 125 files have no icon-only controls.** They are non-UI files, or views whose controls all carry words:

- `AppModel*.swift` (31 files), stores and persistence, `PowerKeeper`, `RelativeDate`, `TCPProbe`, `LocalNetworkCheck`, `HostMetrics`, `HostModeController`, `Greta`, `PrivilegedHelper` and similar;
- views such as `AboutView`, `AddHostView`, `SupportBundleView`, `SetupAssistantView`, `ExportConfigurationView`, `ImportConfigurationView`, `PushDefinitionView`, `ModalCard` and `Wordmark`.
