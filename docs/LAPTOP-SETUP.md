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
   (The Development vault gets whitelisted automatically by the setup script's
   `agent.toml` entry.)

2. **Authenticate gh as melonfleet** (needed to clone the private repo):
   ```sh
   gh auth login          # GitHub.com → SSH → skip key upload → web → authorize as melonfleet
   gh auth switch --user melonfleet
   ```

3. **Clone the repo:**
   ```sh
   gh repo clone melonfleet/flotilla ~/Desktop/Flotilla
   cd ~/Desktop/Flotilla
   ```

4. **Run the local setup script** (SSH config, 1Password agent vault, commit
   signing, known_hosts — all scriptable bits):
   ```sh
   bash scripts/setup-mac.sh
   ```

5. **Bring up `container`:**
   ```sh
   container system kernel set --recommended   # downloads the Linux kernel
   container system start
   container system status                       # expect status: running
   ```

6. **Verify everything:**
   ```sh
   swift build && swift test          # scaffold compiles, 6 fixture tests pass
   swift run flotilla-probe           # round-trips against local container
   ssh -T git@github-melonfleet       # → "Hi melonfleet!"  (Touch ID via 1Password)
   git commit --allow-empty -m "test signing" && git log -1 --show-signature
   #   → "Good signature"  (Touch ID prompt). Then: git reset --hard HEAD~1
   ```

7. **Start building** — open `PROMPTS.md`, paste the **Phase 0** prompt (re-confirm
   green) then **Phase 1**. See `docs/AI-WORKFLOW.md` for how Claude + Codex split work.

## Notes

- The Xcode app target (MenuBarExtra + Liquid Glass) is created during Phase 1;
  `swift build`/`swift test` cover `FlotillaCore` + `flotilla-probe` until then.
- Signing config is **repo-local** (in `.git/config`), so it isn't cloned — that's
  why step 4 re-applies it on this machine.
- The 1Password agent + key are per-machine state; they're already handled by
  1Password sync + the script, so there's nothing to copy from the other Mac.
