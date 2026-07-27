# Flotilla — laptop setup

Instructions to bring up Flotilla on the **M2 Max laptop** (macOS 26) from scratch.
Written so Claude Code on the laptop can drive most of it; steps marked **[you]**
need the GUI and are yours to do.

> Nothing secret is hand-copied. The melonfleet SSH key lives in **1Password
> (Development vault)** and syncs to the laptop automatically. The repo comes from
> GitHub. This doc just wires up local config.

## Prerequisites

- **macOS 26** (Tahoe), Apple Silicon — already the M2 Max.
- **Xcode 26** (App Store) for the Swift 6.x toolchain + macOS 26 SDK. Verify:
  `swift --version` (expect 6.x, target arm64-apple-macosx26).
- **1Password** desktop app — already installed; sign in so the **Development**
  and **Personal** vaults sync.
- **gh CLI** — `brew install gh`.
- **Apple `container`** — install the signed pkg from
  https://github.com/apple/container/releases (needs admin).

## Steps

1. **[you]** In 1Password → **Settings → Developer → enable "Use the SSH agent."**
   Confirm the required development vault is available to the agent.

2. **Authenticate gh as melonfleet** (needed to clone the private repo):
   ```sh
   gh auth login          # GitHub.com → SSH → skip key upload → web → authorize as melonfleet
   gh auth switch --user melonfleet
   ```

3. **Get the repo:** if you copied `~/melonfleet/` from the other Mac, it's already
   at `~/melonfleet/Flotilla` — just `cd` in. Otherwise clone it:
   ```sh
   gh repo clone melonfleet/flotilla ~/melonfleet/Flotilla
   cd ~/melonfleet/Flotilla
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
   ssh -T git@github-melonfleet       # → "Hi melonfleet!"  (Touch ID via 1Password)
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
- The 1Password agent + key are per-machine state; confirm them after 1Password
  sync rather than copying key material between Macs.
