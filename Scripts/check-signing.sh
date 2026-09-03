#!/usr/bin/env bash
#
# Where am I in the signing setup, and what is the next action?
#
# Run this at any point during the Apple Developer setup. It only *reads* — it never creates a
# certificate, never touches a keychain, and never handles a credential. Each step prints PASS or
# the exact next thing to do.
#
# See RELEASING.md for the reasoning behind each step.
set -uo pipefail

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
todo() { printf '  \033[33m→\033[0m %s\n' "$1"; ((remaining++)); }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; ((remaining++)); }
remaining=0

echo "Flotilla signing readiness"
echo

# ---------------------------------------------------------------- 1. WWDR intermediate
# Without it a Developer ID certificate is present but untrusted, and `find-identity` will not
# list it as valid — which looks exactly like the certificate failing to install.
if [ "$(security find-certificate -a -c "Apple Worldwide Developer Relations" 2>/dev/null | grep -c labl)" -gt 0 ]; then
    pass "Apple WWDR intermediate certificate installed"
else
    fail "WWDR intermediate missing — download from https://www.apple.com/certificateauthority/ and double-click"
fi

# ---------------------------------------------------------------- 2. the certificate + its key
# `-p codesigning` is the filter that matters: it lists identities usable for signing, which means
# the certificate AND its private key are both present. A certificate on its own is not an
# identity, and that distinction is the whole reason step 3 exists.
IDS="$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" || true)"
COUNT="$(printf '%s' "$IDS" | grep -c . || true)"
if [ "$COUNT" -eq 0 ]; then
    todo "No 'Developer ID Application' identity yet."
    echo "      Xcode ▸ Settings ▸ Accounts ▸ + ▸ Apple ID (sign in)"
    echo "      then select the team ▸ Manage Certificates… ▸ + ▸ Developer ID Application"
elif [ "$COUNT" -eq 1 ]; then
    pass "Developer ID Application identity present"
    printf '      %s\n' "$(printf '%s' "$IDS" | sed 's/^ *[0-9]*) //')"
else
    pass "$COUNT Developer ID Application identities present"
    printf '%s\n' "$IDS" | sed 's/^ *[0-9]*) /      /'
    echo "      More than one, so release.sh will ask you to name it:"
    echo "      FLOTILLA_SIGN_IDENTITY='Developer ID Application: NAME (TEAMID)' Scripts/release.sh"
fi

# ---------------------------------------------------------------- 3. private key backed up
# Cannot be checked — a .p12 could be anywhere, and searching the disk for one would be worse than
# asking. Stated as a reminder because it is the only unrecoverable step: the private key exists
# only on the Mac that requested the certificate. Losing it means revoking and reissuing.
if [ "$COUNT" -gt 0 ]; then
    echo "  ? Private key backed up? (cannot be verified from here)"
    echo "      Keychain Access ▸ select the certificate AND its key ▸ right-click ▸ Export as .p12"
    echo "      Losing it means revoking and reissuing, not re-downloading."
fi

# ---------------------------------------------------------------- 4. notarisation credential
PROFILE="${FLOTILLA_NOTARY_PROFILE:-flotilla}"
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    pass "notarytool credential stored under profile '$PROFILE'"
else
    todo "No notarytool credential under profile '$PROFILE'."
    echo "      App Store Connect ▸ Users and Access ▸ Integrations ▸ App Store Connect API"
    echo "      Generate a Team Key with the Developer role, download AuthKey_XXXXXXXX.p8 (once!),"
    echo "      note the Key ID and Issuer ID, then run — yourself, so no script sees the key:"
    echo "        xcrun notarytool store-credentials $PROFILE \\"
    echo "          --key ~/Downloads/AuthKey_XXXXXXXX.p8 --key-id KEY_ID --issuer ISSUER_UUID"
fi

# ---------------------------------------------------------------- 5. a version to release
if git describe --tags --abbrev=0 >/dev/null 2>&1; then
    pass "git tag present: $(git describe --tags --abbrev=0)"
else
    todo "No git tag. A release needs one — 0.0.0 is useless to a tester."
    echo "      git tag -a v1.0.0 -m 'v1.0.0'"
fi

echo
if [ "$remaining" -eq 0 ]; then
    echo "Ready. Scripts/release.sh will sign, notarise, staple and verify."
else
    echo "$remaining step(s) remaining — all of them need your Apple credentials, which is why"
    echo "they are yours to run. Re-run this script to check progress."
fi
