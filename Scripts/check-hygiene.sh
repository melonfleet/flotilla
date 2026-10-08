#!/usr/bin/env bash
#
# No real identity, credentials, or key files in tracked files.
#
# The rule has been in CLAUDE.md from the start and was broken anyway, twice: `inspect-volume.json`
# kept the account name because `container` escapes forward slashes in JSON (`\/Users\/name\/`), so
# the obvious `sed 's|/Users/name/|…|'` matched nothing and reported success — and the diagnostics
# tests used the real surname as redactor input for weeks. Remembering a rule is not a control.
#
# ## Why it looks for names, not shapes
#
# The first version of this flagged every `/Users/...` path and every token-shaped string, and
# produced **twenty-nine** findings on its first run — all of them correct code: `/Users/someone` in
# an allowlist comment, `/Users/alice` in a security review, `/Users/mallory` in a redaction
# docstring, and the deliberately realistic `ghp_…` / `-----BEGIN RSA PRIVATE KEY-----` values that
# are the redactor's own test corpus and would be testing nothing if they were fake-looking.
#
# A check that cries wolf gets switched off, or "fixed" by weakening it until it catches nothing. So
# the generic path rule is gone. What remains is exact: the account names that must never appear, the
# credential shapes with the two test corpora named as exclusions, and tracked key files. The real
# leak was an account name, and this catches account names.
set -uo pipefail
cd "$(dirname "$0")/.."

# The identifiers themselves come from Scripts/lib/identities.sh, derived from the host so that
# this file names nobody. Both real incidents were exactly an account name: a fixture that kept it
# because the escaped-slash `sed` missed, and a doc quoting an unredacted `userSetup.username`.
. "$(dirname "$0")/lib/identities.sh"
IDENTITIES="$FL_IDENTITIES"

if [ -z "$IDENTITIES" ]; then
    echo "note: identity check skipped — no personal account name on this host (CI runner or"
    echo "      generic account). Run it on a development machine to check for real names."
fi

# The **first name** was a separate question, left open as a count rather than a failure: it had
# appeared as design attribution — "<name>'s call", "<name> spotted" — which is provenance for a
# decision rather than an identifier in data, and sweeping it would have flattened the reasoning in
# every docstring it appeared in.
#
# **The owner settled it on 14 September: scrub.** The last five went with it — two were genuine
# identifiers in test data (a `--username` operand, an account email) and belonged under the
# stricter rule anyway; three were prose standing in for "the person using this app", which the
# second person says just as well. The count should now read zero.
#
# Still advisory rather than fatal, because what it now guards is reintroduction, and the honest
# reading of one new mention is "look at this" rather than "the build is broken". Make it fatal by
# moving it above the `fail` check if that ever stops being true.
ATTRIBUTION="$FL_FIRST_NAME"

# Files that exist in order to contain realistic fake secrets. Named individually rather than
# matched by pattern, so adding one is a deliberate act that shows up in a diff.
REDACTOR_CORPORA=(
    ':(exclude)Tests/FlotillaCoreTests/DiagnosticsTests.swift'
    ':(exclude)Tests/FlotillaCoreTests/SupportBundleTests.swift'
)

fail=0
self=':(exclude)Scripts/check-hygiene.sh'

# Guarded: an empty pattern makes `grep -E ""` match every line in the repository, so a host that
# yields no derivable identity would "find" everything rather than nothing.
hits=""
[ -n "$IDENTITIES" ] && hits="$(git grep -inE "$IDENTITIES" -- . "$self" 2>/dev/null || true)"
if [ -n "$hits" ]; then
    echo "✗ a real identity appears in tracked files:"
    printf '%s\n' "$hits" | sed 's/^/    /'
    echo "  Use a placeholder — /Users/example in fixtures, someone/alice in prose and tests."
    fail=1
fi

hits="$(git grep -nE 'BEGIN [A-Z ]*PRIVATE KEY|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|xox[baprs]-[0-9]' \
        -- . "$self" "${REDACTOR_CORPORA[@]}" 2>/dev/null || true)"
if [ -n "$hits" ]; then
    echo "✗ credential-shaped material is tracked outside the redactor test corpora:"
    printf '%s\n' "$hits" | sed 's/^/    /'
    fail=1
fi

# Belt and braces over .gitignore: `git add --force` bypasses ignore rules entirely, and the
# signing material this repo now involves (a .p8 API key, an exported .p12) is exactly what someone
# reaches for during a release.
hits="$(git ls-files | grep -iE '\.(p8|p12|cer|pem|key)$|AuthKey_' || true)"
if [ -n "$hits" ]; then
    echo "✗ a key or certificate file is tracked:"
    printf '%s\n' "$hits" | sed 's/^/    /'
    fail=1
fi

# Advisory, never fatal. See ATTRIBUTION above.
attrib="0 mention(s) across 0 file(s)"
[ -n "$ATTRIBUTION" ] && attrib="$(git grep -icE "$ATTRIBUTION" -- . "$self" 2>/dev/null | awk -F: '{n+=$2; f++} END {printf "%d mention(s) across %d file(s)", n, f}')"
case "$attrib" in
    "0 mention(s)"*) ;;
    *) echo "  note: first-name attribution present — $attrib (decision deferred, not a failure)" ;;
esac

if [ "$fail" -ne 0 ]; then
    echo "hygiene FAILED"
    exit 1
fi
echo "  hygiene OK"
