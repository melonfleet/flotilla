# Keyboard shortcut proposal

This is a proposal only. Nothing below is implemented. It is based on the current Containers,
Machines, Images, Volumes, Networks, main-window, and container-detail surfaces.

## Recommend first

Ordered by value:

| Action | Proposed keys | Why |
| --- | --- | --- |
| Focus the current search/filter field | ⌘F | Search is present on every resource list and in Logs and Inspect; the standard Find gesture should reach the visible surface's existing field instead of a generic Find panel. |
| Refresh the visible surface | ⌘R | Every resource list and the Processes, Logs, Inspect, and Configuration panes expose refresh/reload; one contextual command removes repeated pointer travel. |
| Open the selected row | Return | Containers and Machines open detail, while Volumes and Networks open Inspect; Return is the natural keyboard equivalent of the existing double-click/row action. |
| Go back from an embedded detail or form | ⌘[ | Detail and all creation forms have a Back control, so the standard navigation gesture should invoke that exact path, including its unsaved-change handling. |

Availability is part of the proposal. ⌘F and ⌘R should be disabled when the visible surface has no matching action. Return should require exactly one visible selected row; with no selection or an ambiguous multi-selection it should be disabled and do nothing. It must apply only while a resource table has focus, so Return remains the default action in forms. ⌘[ needs no selection, but should be disabled at a section root.

## Useful targeted jumps

| Action | Proposed keys | Why |
| --- | --- | --- |
| Open Logs for the selected container | ⌃⌘L | Logs are the fastest diagnostic destination and currently take a detail open plus a tab change. |
| Open Terminal for the selected container, or Shell for the selected machine | ⌃⌘T | Interactive access is valuable enough to bypass the overflow menu, while one shared mnemonic fits both resource types. |

Both commands require exactly one visible selection. With none or more than one, the menu item should be disabled rather than guessing. Terminal/Shell should additionally be disabled when the selected resource is stopped or the active execution policy refuses an interactive shell. These commands should not fire from a text field or terminal, where keystrokes belong to editing or the shell.

## Do not bind

- **Delete, bulk delete, and image prune:** assign no shortcut. In particular, do not use ⌘Delete: it is a standard destructive binding, deletion here is not recoverable, and the user's confirmation preference can deliberately remove the last dialog. Machine deletion is especially costly because it destroys the VM and anything stored in it.
- **Force Kill:** assign no shortcut. The container object survives, but its process state does not; a mistyped shortcut cannot restore the interrupted work.
- **Direct Start, Stop, or Restart:** leave these on visible controls and menus for now. They are easy to invoke on the wrong retained or multi-selection and Stop/Restart can interrupt work even though the resource can subsequently be started again.

## Conflict ledger

The existing File commands are ⌃⌘R Run Container, ⌃⌘M New Machine, ⌃⌘P Pull Image, ⌃⌘B Build Image, ⌃⌘V New Volume, and ⌃⌘N New Network. None of the proposed shortcuts is an exact collision. ⌘R is deliberately close to ⌃⌘R, however: an extra Control key would open Run rather than refresh, so that near-collision should be tested before accepting the proposal.

⌘F and ⌘R intentionally reuse standard macOS Find and Reload bindings for the same meanings; ⌘[ intentionally follows the standard Back convention. Return is contextual and must never override a form's default button. Keep ⌘W for Close, ⌘, for Settings, and ⌘N for the system's generic New action. Bare arrow keys remain table navigation. Do not assign ⌘Delete at all. The proposed ⌃⌘L and ⌃⌘T do not collide with the six existing File commands or those standard bindings.
