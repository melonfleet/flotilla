# Releasing Flotilla

Two scripts, and a clean division of labour.

| | what it is | signing | needs your Apple account |
|---|---|---|---|
| `Scripts/make-app.sh` | the dev loop | ad-hoc | no |
| `Scripts/release.sh` | a build you can give someone | Developer ID + notarised | yes, via a stored credential |

`make-app.sh` stays exactly as it was: offline, instant, ad-hoc signed. Nothing about the day-to-day
build changes. `release.sh` is the deliberate extra step.

---

## The two things only you can do

Both involve your Apple credentials, so they are yours to run and they happen **once**. After that
`release.sh` works with no secrets in sight: it passes the *name* of a keychain profile, and the
secret stays in the keychain where no script can read it back.

### Step 1 — a Developer ID Application certificate

Signing up for the Developer Program does not create one; you have to ask for it. Right now this
Mac has none, which is what `release.sh` stops on first.

The short path, in Xcode:

1. **Xcode ▸ Settings ▸ Accounts**, add your Apple ID if it is not there.
2. Select the team, **Manage Certificates…**
3. **+** ▸ **Developer ID Application**.

It lands in your login keychain with its private key. Check it took:

```bash
security find-identity -v -p codesigning
```

You want a line reading `Developer ID Application: <your name> (<TEAMID>)`. That ten-character team
ID is the same one that ends up in the bundle's signature.

Two things worth knowing before you need them. **Developer ID certificates are limited per account**
and the private key exists only on the Mac that made the request — so back it up now: Keychain
Access ▸ select the certificate *and* its key ▸ Export as a `.p12`, and keep it somewhere you would
keep a signing key. Losing it means revoking and reissuing, not re-downloading. And **"Developer ID
Application" is the right kind** — "Apple Development" signs builds for your own devices and cannot
notarise; "Apple Distribution" is for the App Store.

### Step 2 — a stored notarisation credential

Notarisation needs to authenticate as you. Use an **App Store Connect API key**, not your Apple ID
password: it is scoped, revocable on its own, and does not carry your account's 2FA around with it.

1. App Store Connect ▸ **Users and Access** ▸ **Integrations** ▸ **App Store Connect API**.
2. Generate a **Team Key** with the **Developer** role.
3. Download the `AuthKey_XXXXXXXX.p8` — **once**; Apple will not offer it again. Note the **Key ID**
   and the **Issuer ID** on that page.

Then store it, in your own terminal:

```bash
xcrun notarytool store-credentials flotilla --key ~/path/AuthKey_XXXXXXXX.p8 --key-id KEY_ID --issuer ISSUER_UUID
```

`flotilla` is the profile name `release.sh` looks for; override with `FLOTILLA_NOTARY_PROFILE`. Check
it took:

```bash
xcrun notarytool history --keychain-profile flotilla
```

Once that is stored, move the `.p8` somewhere safe or delete it — the credential now lives in your
keychain, and a `.p8` sitting in Downloads is a signing key sitting in Downloads.

---

## Releasing

```bash
git tag -a v0.1.0 -m "v0.1.0"
Scripts/release.sh
```

`release.sh` checks everything before it builds anything — clean tree, a real version, a certificate,
a stored credential — because failing in the first second costs nothing and failing after the upload
costs minutes and leaves a half-made artefact. Then it builds release config through `make-app.sh`,
signs with the hardened runtime and a secure timestamp (both notarisation *requirements*, not
preferences), archives with `ditto`, submits, waits, staples, and verifies with `spctl` — the same
check a tester's Mac performs. The result is `dist/Flotilla-<version>.zip`.

Useful variants:

```bash
Scripts/release.sh --version 0.1.1     # name it explicitly instead of from the tag
Scripts/release.sh --skip-notarize     # signed, not notarised — for checking the signing half alone
Scripts/release.sh --allow-dirty       # for testing the pipeline itself, never for a real build
```

### Why a tag is required

`make-app.sh` falls back to version `0.0.0` when there is no tag, which is right for a dev build and
wrong for something you hand to someone: two people comparing "0.0.0" cannot tell which build each
has. `CFBundleVersion` stays the commit count and the exact commit goes in `FLGitDescribe`, which the
diagnostics snapshot reports — so a support bundle names the build precisely even between tags.

---

## What a tester should see

Open the zip, drag Flotilla to Applications, double-click. **No** "unidentified developer" dialog,
no right-click-Open dance, no Gatekeeper prompt beyond the normal first-run "downloaded from the
internet" confirmation. If they see more than that, the fault is the build and not their settings —
`spctl --assess` in the script is the same question their Mac asks.

They will still need Apple's `container` CLI installed, and Flotilla says so on its own when it is
missing. Notarising Flotilla does nothing for that dependency.

## Entitlements: none, deliberately

There is no entitlements file, and that is the correct configuration rather than an omission.
Flotilla is not sandboxed (`DECISIONS.md` — it drives a CLI that manages VMs), and the hardened
runtime with **no** entitlements is the strictest posture available to a non-sandboxed app: nothing
disabled, no exceptions claimed. Spawning `container` needs no entitlement; loading no third-party
libraries means library validation costs nothing.

Add one only in response to a specific, observed failure, and never these two by reflex:
`com.apple.security.cs.disable-library-validation` (we load no external libraries — claiming it
weakens the runtime for nothing) and `com.apple.security.get-task-allow` (a debugging entitlement
that **must not** ship; notarisation rejects it).

## Login items and signing

`SMAppService` keys a login item to the bundle's **signing identity**. Under ad-hoc signing that
identity changes whenever the binary does, which is why "Launch at login" can be refused or silently
forgotten on a dev build. A Developer ID signature is stable across rebuilds, so the login item
registration survives — the first user-visible improvement from this whole exercise, and a reason to
test "Launch at login" on a `release.sh` build rather than a `make-app.sh` one.

---

## Test builds: naming and versioning

`Scripts/make-pkg.sh --version 1.0.0-beta.1` produces a signed, notarised, stapled `.pkg`.
This is what goes to a test Mac. Zips are not distributed.

| Label | Means |
|---|---|
| `1.0.0-alpha.N` | early test build; expect breakage |
| `1.0.0-beta.N` | feature complete, hunting bugs |
| `1.0.0-rc.N` | release candidate — ship it if nothing turns up |
| `1.0.0` | the release |

**One label, two versions**, because they answer different questions:

- **The label** — `1.0.0-beta.1` — is the filename, the About panel, and what a tester quotes back
  to you.
- **The package version** is the **commit count**, and it is what Apple's `installer` compares.

The label cannot serve as the package version. `installer` orders packages numerically, and
`1.0.0-beta.2` is not numerically anything — worse, every beta would compare equal, so the
installer could not tell an older build from a newer one. The commit count only ever increases and
keeps the ordering right across alpha → beta → rc → release.

### Two certificates, not one

A `.pkg` needs **both**, and they are different things people routinely conflate:

- **Developer ID Application** signs the `.app`
- **Developer ID Installer** signs the `.pkg`

A package signed with the Application certificate is not valid, and the error says almost nothing.

### What the package does beyond copying an app

It declares a minimum OS of **26.0**, so it refuses to install where Apple's container runtime
cannot run. An installer that succeeds on macOS 15 and leaves a permanently broken app is worse
than one that declines with a reason.

### Verify before sending it anywhere

```sh
spctl --assess --type install --verbose=4 dist/Flotilla-<label>.pkg   # accepted / Notarized Developer ID
pkgutil --check-signature dist/Flotilla-<label>.pkg                   # Developer ID Installer chain
```

`--type install` is the package equivalent of `--type execute` for an app. Asking the wrong one
passes on a package Gatekeeper would still refuse.

