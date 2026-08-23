# Flotilla — development workstation setup

Generic instructions to bring up Flotilla on a supported Apple Silicon development
workstation. Steps marked **[you]** require local GUI interaction.

> Keep credentials and signing identities in the organization-approved credential
> manager. Do not copy keys into the repository or record personal vault, account,
> device, or filesystem details in this document.

## Prerequisites

- **macOS 26** (Tahoe) on supported Apple Silicon.
- **Xcode 26** (App Store) for the Swift 6.x toolchain + macOS 26 SDK. Verify:
  `swift --version` (expect 6.x, target arm64-apple-macosx26).
- The organization-approved credential manager and SSH agent.
- **gh CLI** — `brew install gh`.
- **Apple `container`** — install the signed pkg from
  https://github.com/apple/container/releases (needs admin).

## Steps

1. **[you]** Enable the approved credential manager's SSH agent. Confirm that the
   required organization-managed development key is available without copying key
   material to disk or recording personal vault names.

2. **Authenticate GitHub CLI** with the approved organization account:
   ```sh
   gh auth login          # GitHub.com → SSH → web authorization
   gh auth status
   ```

3. **Get the repository** using its approved organization URL, then enter the
   Flotilla directory. Do not record a personal home-directory path here:
   ```sh
   gh repo clone ORGANIZATION/REPOSITORY /path/to/workspace/Flotilla
   cd /path/to/workspace/Flotilla
   ```

4. **Configure local repository access and signing.** Follow the settled
   SSH-alias, 1Password SSH-agent, and repo-local signing choices recorded in
   `DECISIONS.md`. Keep personal identity and credentials out of tracked files.

5. **Bring up `container`:**
   ```sh
   container system kernel set --recommended   # downloads the Linux kernel
   container system start
   container system status                       # expect status: running
   ```

6. **Verify everything:**
   ```sh
   swift build && swift test          # core and app compile; 29 tests pass on macOS
   swift run flotilla-probe           # round-trips against local container
   ssh -T APPROVED_GITHUB_SSH_ALIAS   # Verify access through the approved SSH agent
   git commit --allow-empty -m "test signing" && git log -1 --show-signature
   #   → "Good signature"  (Touch ID prompt). Then: git reset --hard HEAD~1
   ```

7. **Continue Phase 1** — open the repository in Claude Code. `CLAUDE.md` is the
   auto-loaded steering document; `PHASE1.md` is the current build contract and
   ownership map.

## Notes

- The SwiftUI app currently builds as the `Flotilla` SwiftPM executable. There is
  no Xcode project yet; create one when app-bundle metadata, `LSUIElement`,
  signing, and distribution require it.
- Signing config is **repo-local** (in `.git/config`), so it isn't cloned — that's
  why step 4 must be repeated on a new machine.
- Credential-manager agents and keys are per-machine state; confirm them through
  the approved manager rather than copying key material between workstations.
