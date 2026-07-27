#!/usr/bin/env bash
# Flotilla — local Mac setup for the melonfleet identity.
# Run once from the repo root on a new Mac (after `gh repo clone`).
# Idempotent: safe to re-run. Handles the scriptable bits; prints manual steps.
set -euo pipefail

PUB='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH2knuyxY6lOlZcpwf6cDMc+CczgbIPO1vT7LV1sWyh5 melonfleet'
NOREPLY='298222390+melonfleet@users.noreply.github.com'
KEYPUB="$HOME/.ssh/id_ed25519_melonfleet.pub"
SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
SSH_CONF="$HOME/.ssh/config"
AGENT_TOML="$HOME/.config/1Password/ssh/agent.toml"
OP_SIGN="/Applications/1Password.app/Contents/MacOS/op-ssh-sign"

mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

# Public key file (not secret) — referenced by ssh config + signing.
printf '%s\n' "$PUB" > "$KEYPUB"; chmod 644 "$KEYPUB"
printf '%s %s\n' "$NOREPLY" "$PUB" > "$HOME/.ssh/allowed_signers"

# ssh config: 1Password agent globally + melonfleet host alias.
touch "$SSH_CONF"; chmod 600 "$SSH_CONF"
grep -q 'com.1password/t/agent.sock' "$SSH_CONF" \
  || printf '\nHost *\n    IdentityAgent "%s"\n' "$SOCK" >> "$SSH_CONF"
grep -q 'Host github-melonfleet' "$SSH_CONF" \
  || printf '\nHost github-melonfleet\n    HostName github.com\n    User git\n    IdentityFile %s\n    IdentitiesOnly yes\n' "$KEYPUB" >> "$SSH_CONF"

# 1Password agent.toml: serve Personal + Development vaults.
mkdir -p "$(dirname "$AGENT_TOML")"
if [ ! -f "$AGENT_TOML" ]; then
  printf '[[ssh-keys]]\nvault = "Personal"\n\n[[ssh-keys]]\nvault = "Development"\n' > "$AGENT_TOML"
elif ! grep -q 'vault = "Development"' "$AGENT_TOML"; then
  printf '\n[[ssh-keys]]\nvault = "Development"\n' >> "$AGENT_TOML"
fi

# Trust github.com host key up front.
ssh-keyscan github.com 2>/dev/null >> "$HOME/.ssh/known_hosts" || true
[ -f "$HOME/.ssh/known_hosts" ] && sort -u "$HOME/.ssh/known_hosts" -o "$HOME/.ssh/known_hosts" || true

# Repo-local commit signing via 1Password (only if run inside the repo).
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git config gpg.format ssh
  git config gpg.ssh.program "$OP_SIGN"
  git config user.signingkey "$KEYPUB"
  git config user.name "melonfleet"
  git config user.email "$NOREPLY"
  git config commit.gpgsign true
  git config gpg.ssh.allowedSignersFile "$HOME/.ssh/allowed_signers"
  echo "OK: repo-local git signing configured (melonfleet, 1Password)"
else
  echo "NOTE: not inside a git repo — run from the cloned flotilla/ folder to set signing"
fi

cat <<'EOF'

--- Manual steps remaining ---
1. 1Password app -> Settings -> Developer -> enable "Use the SSH agent".
2. gh auth login   (GitHub.com -> SSH -> skip upload -> web -> authorize as melonfleet)
   gh auth switch --user melonfleet
3. Verify:
     ssh -T git@github-melonfleet            # "Hi melonfleet!"
     swift build && swift test               # green
EOF
