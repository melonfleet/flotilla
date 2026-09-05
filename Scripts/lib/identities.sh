# Personal identifiers that must not appear in this repository, derived from the host rather than
# written down.
#
# Sourced by check-hygiene.sh (working tree) and check-history.sh (every blob ever committed).
# One definition, because two copies of a rule disagree eventually and the disagreement is the bug.
#
# Sets:
#   FL_IDENTITIES     regex alternation of account name and surname, or empty if none derivable
#   FL_FIRST_NAME     first name, lowercased, or empty
#
# Deriving instead of hardcoding is the point: the previous version wrote the account name and
# surname into the checker and then excluded that file from its own search, so the one file
# guaranteed to contain the identity it protected was the checker, and reading it told you the name.

fl_derive_identities() {
    local account full first last out=()
    account="$(id -un 2>/dev/null || true)"
    full="$(id -F 2>/dev/null || true)"          # macOS only; empty on Linux CI
    first="$(printf '%s' "$full" | awk '{print tolower($1)}')"
    last="$(printf '%s' "$full" | awk 'NF{print tolower($NF)}')"

    # Generic build accounts are skipped: on a CI runner the account is `root` or `runner`, and
    # matching those would flag every honest mention of running as root.
    for name in "$account" "$last"; do
        case "$name" in
            root|runner|builder|ubuntu|nobody|admin|user|"") continue ;;
        esac
        [ "${#name}" -ge 4 ] || continue
        out+=("$name")
    done

    # ${out[*]-} rather than ${out[*]}: under `set -u` an empty array is an unbound variable, and
    # the CI path — where nothing is derivable — is exactly the empty case.
    FL_IDENTITIES="$(IFS='|'; echo "${out[*]-}")"
    FL_FIRST_NAME="$first"
}

fl_derive_identities
