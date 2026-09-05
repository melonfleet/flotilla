#!/usr/bin/env bash
#
# No real identity, credentials, or key files anywhere in the repository's HISTORY.
#
# ## Why this exists as its own check
#
# `check-hygiene.sh` reads the working tree, and the working tree was clean. Publishing a repository
# publishes every commit in it, and the history was not clean: the account name and surname appeared
# in 136 of 143 commits, across seven files that had all since been fixed or deleted — captured
# fixtures, the diagnostics redaction tests, CLAUDE.md, research/BRIEF.md. Deleting a file does not
# unpublish it. A tree-only check reports success right up to the moment the repository goes public.
#
# So this is the gate to run **before making a repository public**, and after any history rewrite,
# and it is deliberately not wired into make-app.sh: it is slow, and it answers a question that only
# arises at publication.
#
# Exit 0 means the history is safe to publish. Exit 1 means it is not, and lists where.
set -uo pipefail
cd "$(dirname "$0")/.."

. "$(dirname "$0")/lib/identities.sh"

fail=0
revs="$(git rev-list --all)"
[ -n "$revs" ] || { echo "  no commits"; exit 0; }
n_revs="$(printf '%s\n' "$revs" | wc -l | tr -d ' ')"
echo "scanning $n_revs commits…"

# --- identity
if [ -z "$FL_IDENTITIES" ]; then
    echo "note: identity scan skipped — no personal account name on this host (CI runner or"
    echo "      generic account). Run it on a development machine before publishing."
else
    # -l, then strip the rev prefix: the same blob appears in every commit that contains it, so
    # counting raw matches reports thousands of hits for one mistake and buries the actual list.
    files="$(git grep -lIE "$FL_IDENTITIES" $revs -- 2>/dev/null | awk -F: '{print $2}' | sort -u || true)"
    if [ -n "$files" ]; then
        echo "✗ a real identity appears in the history of these files:"
        printf '%s\n' "$files" | sed 's/^/    /'
        echo "  These are unreachable by editing the working tree. Either rewrite the history"
        echo "  (git filter-repo --replace-text) or publish from a fresh repository."
        fail=1
    fi
fi

# --- credentials. The redactor's own test corpora are excluded by path, the same two files
# check-hygiene.sh names, because realistic fake secrets are the whole point of them.
creds="$(git grep -lIE 'BEGIN [A-Z ]*PRIVATE KEY|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|xox[baprs]-[0-9]' \
         $revs -- \
         ':(exclude)Tests/FlotillaCoreTests/DiagnosticsTests.swift' \
         ':(exclude)Tests/FlotillaCoreTests/SupportBundleTests.swift' \
         ':(exclude)Scripts/check-hygiene.sh' \
         ':(exclude)Scripts/check-history.sh' 2>/dev/null | awk -F: '{print $2}' | sort -u || true)"
if [ -n "$creds" ]; then
    echo "✗ credential-shaped material appears in the history of these files:"
    printf '%s\n' "$creds" | sed 's/^/    /'
    fail=1
fi

# --- key files ever committed, whether or not they are still present
keys="$(git log --all --pretty=format: --name-only --diff-filter=A 2>/dev/null \
        | sort -u | grep -iE '\.(p8|p12|cer|pem|key)$|AuthKey_' || true)"
if [ -n "$keys" ]; then
    echo "✗ a key or certificate file was committed at some point:"
    printf '%s\n' "$keys" | sed 's/^/    /'
    echo "  Treat the material as compromised and rotate it, then rewrite the history."
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "  history OK — safe to publish"
else
    echo "history FAILED — do not make this repository public yet"
fi
exit "$fail"
