# Deep Research: Is Flotilla's Versioning Scheme Right?

**Author:** Research Analysis for Kamal  
**Date:** 19 October 2026  
**Repository State Inspected:** Commit count `565` (`HEAD`), latest public tag `v1.5.0.0-beta.4` (build `422`)  
**Scope:** Research only — no code or repository files modified.

---

## Executive Summary & Verdict

**No — Flotilla's `<container version>.<Flotilla revision>` (`1.5.0.0`) versioning scheme is no longer suitable, and Flotilla should switch to independent 3-part Semantic Versioning (`MAJOR.MINOR.PATCH`, starting right now at `1.5.0-beta.5` → `1.5.0` final) before shipping its first stable 1.5 release.**

When the four-component scheme (`1.4.1.0` → `1.5.0.0`) was chosen on 12 September 2026 ([`DECISIONS.md`](DECISIONS.md#L509-L562)), Flotilla was a local single-Mac GUI wrapper around Apple's `container` CLI, and its built-in GitHub release checker (`UpdateCheck`) needed to parse the first three numbers of Flotilla's tag to decide whether a newer `container` runtime existed. Since then, **three fundamental things have changed**:

1. **The technical mechanism that motivated the scheme was deleted.** On 8 October 2026 ([`DECISIONS.md` Q40](DECISIONS.md#L1935-L1963)), Flotilla replaced `UpdateCheck` with Sparkle 2. Today, [`SemanticVersion.revision`](Sources/FlotillaCore/SemanticVersion.swift#L35-L45) and [`SemanticVersion.runtimeComponents`](Sources/FlotillaCore/SemanticVersion.swift#L42-L44) have **zero production callers** in the entire repository. Flotilla determines the target `container` version from the hardcoded constant [`ContainerRuntime.expectedVersion = "1.5.0"`](Sources/FlotillaCore/ContainerPackage.swift#L10) and minimum version [`Preflight.defaultMinimumVersion = VersionTriple(1, 0, 0)`](Sources/FlotillaCore/Preflight.swift#L18) — never from its own version number.
2. **Flotilla's own roadmap already uses `1.5` and `2.0` as Flotilla product versions, not `container` versions.** Since October 2026, Flotilla has grown into a multi-host fleet manager with an mTLS wire protocol (v13), a privileged daemon (`FlotillaHelper` v5), a cloud-scanned Suggestions & Vulnerability library, and an on-device AI assistant (Greta). Both [`DECISIONS.md`](DECISIONS.md#L2226-L2378) and [`PLAN.md`](PLAN.md#L797-L841) define **"1.5"** (Greta on-device, manual migration, keep-awake) and **"2.0"** (fleet ledger, host-to-host tunnels, high availability, Jamf/MDM, Runtime Saver, Flotilla Web & iPad) as Flotilla product milestones.
3. **A 4-part `CFBundleShortVersionString` (`1.5.0.0`) violates Apple's platform specification (TN2420) and is silently truncated by both Apple's `PackageKit` and Flotilla's own [`VersionSkew`](Sources/FlotillaCore/Fleet/VersionSkew.swift#L22-L35) parser.** Every universal GUI wrapper and desktop orchestrator in prior art — including **Docker Desktop**, **Podman Desktop**, **Rancher Desktop**, **OrbStack**, **CodeWeavers CrossOver**, **Sourcetree/Tower/Fork**, **Orchard**, and even **Apple's own `apple/container` (`1.5.0`) relative to `apple/containerization` (`0.52.0`)** — uses an independent 3-part product version and communicates engine compatibility via metadata and UI.

Because Sparkle, Apple's `/usr/sbin/installer`, LaunchServices, and Flotilla's Host Self-Update all compare **`CFBundleVersion`** (the monotonic git commit count, currently `422` in `1.5.0.0-beta.4` and `565` at `HEAD`), Flotilla can drop the 4th component immediately in **`1.5.0-beta.5`** (or **`1.5.0`** final) with **zero update-ordering breakage** for existing beta users.

---

## 0. Audit of Flotilla's Current Versioning Architecture

Before examining external prior art, we audited every place in the Flotilla repository where versions are stamped, parsed, displayed, or compared.

### 0.1 How Versions Are Stamped Today
| Artifact / Field | Source Script & Line | Value in `v1.5.0.0-beta.4` | Value on Un-tagged Dev Builds |
| :--- | :--- | :--- | :--- |
| **`CFBundleShortVersionString`** | [`Scripts/make-app.sh:109-147`](Scripts/make-app.sh#L109-L147) | `1.5.0.0-beta.4` | `<last-tag>+<commits-since-tag>` (or `0.0.0` if no tag) |
| **`CFBundleVersion`** | [`Scripts/make-app.sh:104-106`](Scripts/make-app.sh#L104-L106) | `422` (`git rev-list --count HEAD`) | `565` (monotonic commit count) |
| **`FLGitDescribe`** | [`Scripts/make-app.sh:151-155`](Scripts/make-app.sh#L151-L155) | `v1.5.0.0-beta.4` | `v1.5.0.0-beta.4-143-g...` |
| **Helper `CFBundleVersion`** | [`Scripts/make-app.sh:215-221`](Scripts/make-app.sh#L215-L221) | `422` (stamped into `FlotillaHelper` `__ info_plist` section) | `565` |
| **`.pkg` `--version`** | [`Scripts/make-pkg.sh:70-76,141`](Scripts/make-pkg.sh#L70-L76) | `422` (`$PKG_VERSION` = commit count) | `565` |
| **Sparkle `<sparkle:version>`** | [`Scripts/publish-release.sh:121,158`](Scripts/publish-release.sh#L121-L158) | `422` (`CFBundleVersion`) | N/A |
| **Sparkle `<sparkle:shortVersionString>`** | [`Scripts/publish-release.sh:120,159`](Scripts/publish-release.sh#L120-L159) | `1.5.0.0-beta.4` (`CFBundleShortVersionString`) | N/A |

> [!NOTE]
> **Subtle shell-glob bug uncovered in [`Scripts/make-app.sh:118,136-146`](Scripts/make-app.sh#L118-L146):**  
> When building on a commit after a tag, line 118 sets `CANDIDATE="${CANDIDATE}+${SINCE_TAG}"` (e.g., `1.5.0.0-beta.4+143`). Lines 136–146 validate `$CANDIDATE` against `case` patterns such as `[0-9]*.[0-9]*.[0-9]*.[0-9]*-beta.[0-9]*`. In POSIX sh/bash `case` globs, `[0-9]*` means "one digit followed by **any characters**", so trailing `*` accidentally matches `+143`!

### 0.2 What Each Update & Compatibility Path Actually Compares
A critical finding of our codebase audit is that **not a single update mechanism in Flotilla compares `CFBundleShortVersionString` (`1.5.0.0-beta.4`)**:

1. **Sparkle Appcast Updates ([`AppUpdater.swift`](Sources/Flotilla/AppUpdater.swift), [`Scripts/publish-release.sh`](Scripts/publish-release.sh#L155-L171), `gh-pages:appcast.xml`):**
   - `publish-release.sh` writes `CFBundleVersion` (`347`, `392`, `422`) into `<sparkle:version>` and `CFBundleShortVersionString` (`1.5.0.0-beta.2`, `1.5.0.0-beta.3`, `1.5.0.0-beta.4`) into `<sparkle:shortVersionString>`.
   - Sparkle compares `<sparkle:version>` (`422`) against the installed app's `CFBundleVersion`. It treats `<sparkle:shortVersionString>` purely as a display label.
2. **Remote Host Self-Update ([`FleetUpdate.swift:8-27`](Sources/FlotillaCore/Fleet/FleetUpdate.swift#L8-L27), [`SelfUpdate.swift:89-93`](Sources/Flotilla/SelfUpdate.swift#L89-L93), [`FlotillaHelper/main.swift:238-241`](Sources/FlotillaHelper/main.swift#L238-L241)):**
   - [`HostModeController.appVersion`](Sources/Flotilla/HostModeController.swift#L392-L397) formats the wire version string as `"\(short) (\(build))"` (e.g., `"1.5.0.0-beta.4 (422)"`).
   - On the admin Mac, [`FleetUpdate.isOutdated(hostVersion:adminVersion:)`](Sources/FlotillaCore/Fleet/FleetUpdate.swift#L8-L27) extracts the integer inside `(...)` via `build(of:)` and checks `hBuild < aBuild`. If either build number is missing, it returns `false` — it **never** compares the `1.5.0.0` prefix!
   - On the remote host, both [`SelfUpdate.prepare`](Sources/Flotilla/SelfUpdate.swift#L89-L93) and [`FlotillaHelper.installFlotillaUpdate`](Sources/FlotillaHelper/main.swift#L238-L241) parse `CFBundleVersion` as `Int` and enforce `newBuild > ownBuild`.
3. **Apple `.pkg` Installer ([`Scripts/make-pkg.sh:70-76`](Scripts/make-pkg.sh#L70-L76)):**
   - As decided on 5 October 2026 ([`DECISIONS.md:564-575`](DECISIONS.md#L564-L575)), `make-pkg.sh` passes `--version "$PKG_VERSION"` (the git commit count `422`) to `pkgbuild` and `distribution.xml` because Apple's `installer` mishandles `-beta.N` strings.

### 0.3 Dead Code & Three Incompatible Version Parsers in `FlotillaCore`
Because `UpdateCheck` was removed when Sparkle was adopted ([`DECISIONS.md` Q40](DECISIONS.md#L1944)), `FlotillaCore` currently has **three separate version structs** that disagree on Flotilla's own version format:

| Type | File | Components Parsed | Pre-release Handling | Where Used in Production |
| :--- | :--- | :--- | :--- | :--- |
| **[`SemanticVersion`](Sources/FlotillaCore/SemanticVersion.swift#L30-L154)** | `SemanticVersion.swift` | 1–4 (`major`, `minor`, `patch`, `revision`) | Parsed & ordered (`-alpha.1 < nil`) | **Only 1 call site:** [`Models.swift:460`](Sources/FlotillaCore/Models.swift#L460) (extracting 3-part `container-apiserver` version). `.revision` and `.runtimeComponents` have **0 callers outside tests**! |
| **[`SoftwareVersion`](Sources/FlotillaCore/Fleet/VersionSkew.swift#L5-L45)** | `VersionSkew.swift` | **Only 3** (`major`, `minor`, `patch`) + optional `(build)` | Stripped (`1.5.0-rc1` → `1.5.0`) | [`VersionSkew.compare`](Sources/FlotillaCore/Fleet/VersionSkew.swift#L55-L85), [`ContainerPackage.swift:106,127`](Sources/FlotillaCore/ContainerPackage.swift#L106-L127), [`ImageTransfer.swift:8`](Sources/FlotillaCore/Fleet/ImageTransfer.swift#L8). **Silently ignores `parts[3]` (the 4th component)!** |
| **[`VersionTriple`](Sources/FlotillaCore/Preflight.swift#L205-L236)** | `Preflight.swift` | **Strictly 3** (`major`, `minor`, `patch`) | Boolean flag `isPrerelease` | [`Preflight.swift:18,225`](Sources/FlotillaCore/Preflight.swift#L18) (`defaultMinimumVersion = 1.0.0`). Rejects 4-component strings (`parts.count == 3`). |

Look closely at [`SoftwareVersion.init?(parsing:)`](Sources/FlotillaCore/Fleet/VersionSkew.swift#L29-L33):
```swift
let parts = verPart.split(separator: ".", omittingEmptySubsequences: false)
guard parts.count >= 2,
      let major = Int(parts[0]),
      let minor = Int(parts[1]) else { return nil }
let patch = parts.count >= 3 ? (Int(parts[2]) ?? 0) : 0
```
`SoftwareVersion` never reads `parts[3]`. If two Flotilla versions are compared without parenthesized build numbers — e.g., `SoftwareVersion(parsing: "1.5.0.0")` vs `SoftwareVersion(parsing: "1.5.0.5")` — `VersionSkew.compare` reports **`.same`**! It only works on live hosts today because [`HostModeController.appVersion`](Sources/Flotilla/HostModeController.swift#L395) appends `(\(build))`, and [`VersionSkew.compare`](Sources/FlotillaCore/Fleet/VersionSkew.swift#L67-L69) falls through to comparing `lb != rb` (the `CFBundleVersion` build integer).

### 0.4 How Flotilla Actually Tracks `container` Compatibility and Other Schemas
Flotilla already decouples its runtime checks and internal schemas from its app version string:
- **Expected `container` version:** [`ContainerRuntime.expectedVersion = "1.5.0"`](Sources/FlotillaCore/ContainerPackage.swift#L10) (used by onboarding, runtime upgrade banners, and fleet `container` updates).
- **Minimum `container` version:** [`Preflight.defaultMinimumVersion = VersionTriple(1, 0, 0)`](Sources/FlotillaCore/Preflight.swift#L18) (plus feature gates like [`ImageTransfer.minimumContainer = SoftwareVersion(major: 1, minor: 3, patch: 1)`](Sources/FlotillaCore/Fleet/ImageTransfer.swift#L8)).
- **Fleet Wire Protocol:** [`WireProtocol.supportedVersions: ClosedRange<UInt16> = 1...13`](Sources/FlotillaCore/Wire/WireFrame.swift#L28).
- **Privileged Helper XPC Interface:** [`HelperInterface.version = 5`](Sources/FlotillaPrivileged/HelperInterface.swift#L32).
- **Suggestions Catalog:** [`SuggestionLibrary`](Sources/FlotillaCore/SuggestionLibrary.swift#L31-L99) uses **CalVer `YYYY.MM.DD.N`** (`"2026.10.12.0"`) for data freshness and an integer `schema = 2` (`currentSchema = 2`) for format compatibility.
- **Vulnerability Report:** [`VulnerabilityReport.currentSchema = 1`](Sources/FlotillaCore/VulnerabilityReport.swift#L18-L32) + ISO-8601 `generated` timestamp.

---

## 1. Question 1: Prior Art Across the Industry

We surveyed 12 categories of real-world software that wrap, bundle, or drive an upstream product with its own versioning.

### 1.1 Docker Desktop vs. Docker Engine and Docker Compose
Docker is the closest historical analogue to Flotilla — and **Docker explicitly tried coupling its desktop version to the engine version before abandoning it in December 2018.**

- **Current Scheme (Independent SemVer across all components):**
  - **Docker Desktop:** `4.x.y` (e.g., `4.38.0`, `4.40.0+`), tracking the macOS/Windows/Linux GUI, VM lifecycle, networking/file-sharing stack, and enterprise features ([Docker Desktop Release Notes](https://docs.docker.com/desktop/release-notes/)).
  - **Docker Engine (`dockerd` & `docker` CLI):** `27.x.y` / `28.x.y` / `29.x.y` ([Docker Engine 27 Release Notes](https://docs.docker.com/engine/release-notes/27/), [Docker Engine 28 Release Notes](https://docs.docker.com/engine/release-notes/28/)).
  - **Docker Compose:** `v2.x.y` / `v5.x.y` ([Docker Compose Release Notes](https://docs.docker.com/compose/releases/release-notes/), [`github.com/docker/compose/releases`](https://github.com/docker/compose/releases)).
  - **Docker Buildx:** `v0.x.y` ([Docker Build Release Notes](https://docs.docker.com/build/release-notes/), [`github.com/docker/buildx/releases`](https://github.com/docker/buildx/releases)).
  - **Kubernetes:** `v1.x.y` (upstream CNCF release bundled in Desktop).
- **Why Docker Abandoned Engine-Coupled Versioning:**
  1. *2016 – Feb 2017 (`1.12.x`–`1.13.1`):* Early *Docker for Mac* tracked Docker Engine's `1.12`/`1.13` version ([Prior Docker Engine Release Notes](https://docs.docker.com/engine/release-notes/prior-releases/)).
  2. *March 2017 – Nov 2018 (`17.03`–`18.06`):* Docker Engine switched to `YY.MM` CalVer (`17.03`), and *Docker CE for Mac* mirrored it with build suffixes (`17.03.0-ce-mac1` through `18.06.1-ce-mac73`) ([Docker 17.03 Release Notes](https://docs.docker.com/engine/release-notes/17.03/)).
  3. *December 2018 (`Docker Desktop 2.0.0.0`):* When Engine shipped `18.09`, Docker rebranded *Docker for Mac/Windows* to **Docker Desktop** and decoupled its version to **`2.0.0.0`** (bundling Engine `18.09.0`, Compose `1.23.2`, Machine `0.16.0`), progressing through `2.x` → `3.x` → `4.x` ([Docker Desktop 2.x Archive Release Notes](https://docs.docker.com/desktop/previous-versions/2.x-mac/)). **Reason:** Desktop had become a multi-component product (hypervisor VM, VPNKit, VirtioFS, GUI dashboard, Kubernetes) that needed to ship macOS/Windows fixes and major UI features on a much faster cadence than the Linux daemon.
  4. *February 2023 (`Docker Engine 23.0.0`):* Docker Engine itself abandoned `YY.MM` CalVer and returned to `MAJOR.MINOR.PATCH` SemVer at `23.0.0` because leading-zero months (`.03`, `.09`) violated Go module SemVer rules and obscured breaking changes ([Docker Engine 23.0 Release Notes](https://docs.docker.com/engine/release-notes/23.0/)).
- **How Compatibility Is Communicated:**
  - Every entry on [Docker Desktop Release Notes](https://docs.docker.com/desktop/release-notes/) has an explicit **Upgrades** component manifest (*Docker Engine*, *Compose*, *Buildx*, *Kubernetes*, *containerd*, *runc*).
  - **About Docker Desktop** displays `Docker Desktop 4.x.y (<build>)` at the top and a component table below it.
  - `docker version` prints `Server: Docker Desktop 4.38.0 (181591)` alongside `Engine: Version: 27.5.1` ([`docker version` CLI Reference](https://docs.docker.com/reference/cli/docker/version/)).

### 1.2 Rancher Desktop, Podman Desktop, OrbStack, and Colima
Every single macOS container desktop alternative uses **independent SemVer** for the application:

| Product | App Version | Bundled / Driven Engine Versions | Why Decoupled & How Communicated |
| :--- | :--- | :--- | :--- |
| **Rancher Desktop** | `1.0.0` → `1.24.0` ([Releases](https://github.com/rancher-sandbox/rancher-desktop/releases)) | Dynamic K3s (`v1.28.x`–`v1.35.x+`) via [`kuberlr`](https://github.com/flavio/kuberlr), Moby `29.6.2`, `nerdctl 2.2.2`, Compose `5.3.1`, Lima | Users can switch, upgrade, or downgrade the Kubernetes/K3s version at runtime in **Preferences → Kubernetes** ([Docs](https://docs.rancherdesktop.io/ui/preferences/kubernetes/), [Upgrade Guide](https://docs.rancherdesktop.io/how-to-guides/upgrade-kubernetes/)) without changing Rancher Desktop's version. Release notes include an *"Updates to Bundled Utilities"* diff table. |
| **Podman Desktop** | `1.0.0` → `1.30.5` ([Releases](https://github.com/podman-desktop/podman-desktop/releases)) | Podman CLI `4.x` / `5.8.x` / `6.1.x` ([Podman Releases](https://github.com/containers/podman/releases)), plus Docker, Lima, Kind, OpenShift Local | Podman Desktop is a multi-provider UI where Podman is managed via an extension and can be installed/upgraded independently via Homebrew or the onboarding flow ([Podman Desktop Docs](https://podman-desktop.io/docs/intro), [Installation Docs](https://podman-desktop.io/docs/installation)). |
| **OrbStack** | `1.x.y` → `2.2.4` ([Release Notes](https://docs.orbstack.dev/release-notes)) | Docker Engine `v29.8.2`, Compose `v5.5.0`, Buildx `v0.37.2`, K8s `v1.36.5`, Linux Kernel `7.2` | OrbStack's app version represents the integrated macOS virtualization appliance; every release note at [`docs.orbstack.dev/release-notes`](https://docs.orbstack.dev/release-notes) lists the exact bundled upstream versions. |
| **Colima** | `0.x.y` (`v0.10.3`) ([Releases](https://github.com/abiosoft/colima/releases)) | Lima, Docker `v29.2.0`, `nerdctl v2.2.1`, Incus `v6.21`, K3s `v1.35.0+k3s1` | Colima orchestrates a Lima VM; users run `colima update` to upgrade guest runtimes independently of the `colima` CLI binary, and `colima version` prints both CLI and runtime versions ([Colima FAQ](https://github.com/abiosoft/colima/blob/main/docs/FAQ.md)). |

### 1.3 Homebrew Formula Revisions, `version_scheme`, and Casks
- **Formula `version` vs. `revision N` (`<version>_<revision>`, e.g., `1.5.0_1`):**
  - A Homebrew formula packages a **single upstream software release** without adding a separate product layer. When maintainers change packaging, dependencies, or patches without an upstream version bump, they add `revision 1`, which appends `_1` (`1.5.0_1`) so `brew outdated` / `brew upgrade` forces users onto the new package ([Homebrew Formula Cookbook — Formulae Revisions](https://docs.brew.sh/Formula-Cookbook#formulae-revisions)).
  - When upstream ships a new version (`1.5.1`), the `revision` line is removed (resetting to `0`).
- **Bottle `rebuild N` vs. `revision N`:**
  - If a binary bottle is recompiled with no runtime/dependency change requiring already-installed users to upgrade, Homebrew uses `rebuild 1` inside the `bottle do` block instead of `revision 1` ([Homebrew Bottles Docs](https://docs.brew.sh/Bottles)).
- **`version_scheme N` (Homebrew's Epoch):**
  - When an upstream project changes its versioning scheme backwards (e.g., from CalVer `20260101` to SemVer `1.0.0`), Homebrew increments `version_scheme 1` in the formula so `1.0.0` sorts newer than `20260101` ([Homebrew Formula Cookbook — Version Scheme Changes](https://docs.brew.sh/Formula-Cookbook#version-scheme-changes), [Homebrew Versions Docs](https://docs.brew.sh/Versions)).
- **Homebrew Casks (macOS GUI Apps):**
  - Casks use `version "1.2.3,456"` (comma-separated tuple) where `version.csv.first` (`1.2.3`) maps to `CFBundleShortVersionString` and `version.csv.second` (`456`) maps to `CFBundleVersion` ([Homebrew Cask Cookbook — `version` stanza](https://docs.brew.sh/Cask-Cookbook#stanza-version)).

### 1.4 Debian and Ubuntu Package Revisions (`upstream-debianrevision` and Epochs)
- **Format (`[epoch:]upstream_version[-debian_revision]`):**
  - Defined in [Debian Policy Manual §5.6.12 (`Version`)](https://www.debian.org/doc/debian-policy/ch-controlfields.html#s-f-version) and [`deb-version(7)`](https://manpages.debian.org/bookworm/dpkg-dev/deb-version.7.en.html).
  - Because a `.deb` package is a redistribution of a specific upstream tarball, `upstream_version` tracks upstream verbatim and `-debian_revision` (`-1`, `-2`) tracks Debian packaging changes, resetting to `-1` when `upstream_version` advances.
  - Ubuntu appends `ubuntuN` to the Debian revision (`1.2.3-1ubuntu2`), or `-0ubuntu1` if packaged before Debian ([Ubuntu Packaging Guide — Version Strings](https://documentation.ubuntu.com/ubuntu-packaging-guide/), [Ubuntu Security Team Version Strings](https://wiki.ubuntu.com/SecurityTeam/BuildSystem#Version_Strings)).
- **How `dpkg --compare-versions` Compares & The Tilde (`~`) Operator:**
  - [`dpkg(1)`](https://manpages.debian.org/bookworm/dpkg/dpkg.1.en.html) alternates between lexical non-digit comparison and integer digit comparison. Crucially, Debian had to invent a special **`~` (tilde) character** that sorts even before the end of a part (`1.5.0~beta4 < 1.5.0`), because without `~`, `"1.5.0-beta4"` would either be parsed as a `debian_revision` or sort *after* `"1.5.0"`.
- **What `epoch` (`1:1.0.0`) Solves:**
  - An integer prefix (`1:`, `2:`) overrides all comparisons of `upstream_version` when upstream switches versioning schemes non-monotonically or a malformed version was published ([Debian Policy Manual §5.6.12](https://www.debian.org/doc/debian-policy/ch-controlfields.html#s-f-version)). Once an epoch is added, it can **never** be removed without breaking upgrades.

### 1.5 Kubernetes Distributions (K3s, RKE2, GKE, EKS, AKS)
Kubernetes distributions must expose the upstream Kubernetes API version to `kubectl`, kubelet skew policies, and Helm chart `kubeVersion` constraints, which has forced two different workarounds — **both of which hit edge cases in SemVer 2.0.0**:

1. **K3s (`v1.30.2+k3s1`) and RKE2 (`v1.30.2+rke2r1`) — SemVer Build Metadata (`+`):**
   - K3s and RKE2 append `+k3s<N>` / `+rke2r<N>` using SemVer 2.0.0 Rule 10 build metadata syntax ([K3s Upgrades Docs](https://docs.k3s.io/upgrades), [`github.com/k3s-io/k3s`](https://github.com/k3s-io/k3s), [RKE2 Upgrade Docs](https://docs.rke2.io/upgrade/basic_upgrade), [`github.com/rancher/rke2`](https://github.com/rancher/rke2)).
   - **Why `+` instead of `-`:** If they used `-k3s1`, SemVer 2.0.0 Rule 9 treats the version as a **pre-release** of `1.30.2`, causing Helm charts with `kubeVersion: ">= 1.30.0"` to reject the cluster.
   - **The SemVer §10 Trap:** Under [SemVer 2.0.0 Rule 10](https://semver.org/#spec-item-10), *"Build metadata MUST be ignored when determining version precedence. Thus two versions that differ only in the build metadata, have the same precedence."* Consequently, standard SemVer libraries consider **`v1.30.2+k3s1 == v1.30.2+k3s2`**, forcing Rancher to maintain custom version comparators in [`rancher/channelserver`](https://github.com/rancher/channelserver) and [`rancher/system-upgrade-controller`](https://github.com/rancher/system-upgrade-controller) that split on `+k3s` / `+rke2r` and compare the trailing integer manually.
2. **Google GKE (`1.30.2-gke.1000000`) — SemVer Pre-release (`-`):**
   - GKE appends `-gke.<N>` ([GKE Versioning and Upgrades](https://cloud.google.com/kubernetes-engine/docs/concepts/versioning-and-upgrades), [GKE Release Channels](https://cloud.google.com/kubernetes-engine/docs/concepts/release-channels)).
   - **Why `-` instead of `+`:** Standard SemVer comparators sort `1.30.2-gke.1000000 < 1.30.2-gke.2000000`.
   - **The SemVer §9 Trap:** Because `-gke.N` is syntactically a SemVer pre-release, `1.30.0-gke.1000000` has **lower precedence** than `1.30.0`, which notoriously breaks `Masterminds/semver` (used by Helm) unless chart authors write `>= 1.30.0-0`.
3. **AWS EKS (`1.30` + `eks.1` + `vYYYYMMDD`) and Azure AKS (`1.30.2` + `YYYYMM.DD.0`):**
   - **AWS EKS** cleanly separates three numbers rather than jamming them into one string: the **Kubernetes version** (`1.30`), the **EKS Platform Version** (`eks.1`, `eks.2`) for control-plane patches ([EKS Platform Versions](https://docs.aws.amazon.com/eks/latest/userguide/platform-versions.html)), and a CalVer **AMI version** (`v20240828`) for worker node images ([EKS Optimized AMI Docs](https://docs.aws.amazon.com/eks/latest/userguide/eks-optimized-ami.html), [Retrieve AMI ID Docs](https://docs.aws.amazon.com/eks/latest/userguide/retrieve-ami-id.html)).
   - **Azure AKS** uses pure upstream Kubernetes SemVer (`1.30.2`) for the cluster ([AKS Supported Kubernetes Versions](https://learn.microsoft.com/en-us/azure/aks/supported-kubernetes-versions)) and a separate CalVer string (`AKSUbuntu-2204gen2containerd-202408.27.0`) for node OS images ([AKS Node Image Upgrade](https://learn.microsoft.com/en-us/azure/aks/node-image-upgrade)).

### 1.6 Electron & Electron Apps vs. Chromium and Node.js
- **Electron (`MAJOR.MINOR.PATCH`):**
  - Electron bundles Chromium, Node.js, and V8, each with its own massive version number (e.g., Chromium `130.0.6723.x`, Node `20.18.0`, V8 `13.0`), but versions itself on an independent SemVer track (`33.x.y`) ([Electron Versioning Docs](https://www.electronjs.org/docs/latest/tutorial/electron-versioning)).
  - In May 2021 (starting with Electron 15), Electron aligned its **release cadence** with Chromium (shipping a new major Electron version every 8 weeks on even-numbered Chromium milestones) **without adopting Chromium's version number**, because breaking changes in Electron's own APIs and Node.js upgrades also govern its major versions ([Electron 8-Week Cadence Blog](https://www.electronjs.org/blog/8-week-cadence), [Electron Release Timelines](https://www.electronjs.org/docs/latest/tutorial/electron-timelines)).
  - Component versions are exposed programmatically via `process.versions.{electron, chrome, node, v8}` ([Electron `process.versions` API](https://www.electronjs.org/docs/latest/api/process#processversions)).
- **Electron Applications (VS Code, Signal Desktop, Obsidian):**
  - Every major Electron app uses its own product SemVer completely decoupled from Electron/Chromium/Node:
    - **VS Code (`1.94.x`):** Increments `minor` monthly per iteration plan and lists `Electron`, `Chromium`, `Node.js`, and `V8` in `Code > About Visual Studio Code` and at the bottom of its release notes ([VS Code Updates](https://code.visualstudio.com/updates)).
    - **Signal Desktop (`7.x.y`):** Uses independent SemVer ([Signal Desktop Releases](https://github.com/signalapp/Signal-Desktop/releases)).
    - **Obsidian (`1.x.y`):** Uses independent SemVer and displays two lines in **Settings → About**: **Current version** (app JS/asar bundle updated over the air) and **Installer version** (the underlying Electron binary package) ([Obsidian Changelog](https://obsidian.md/changelog/)).

### 1.7 VS Code Extensions and JetBrains Plugins vs. the IDE
- **VS Code Extensions:**
  - Extensions use independent `MAJOR.MINOR.PATCH` in `package.json` `"version"` and declare minimum IDE compatibility in `"engines": { "vscode": "^1.90.0" }` ([VS Code Extension Manifest](https://code.visualstudio.com/api/references/extension-manifest)).
  - Notably, the VS Code Marketplace **forbids pre-release suffixes (`-beta.1`)** in `version`; extensions must use pure 3-integer `major.minor.patch` with the `vsce publish --pre-release` flag, and Microsoft recommends `major.EVEN_NUM.patch` for stable releases and `major.ODD_NUM.patch` for pre-releases ([VS Code Pre-release Extensions](https://code.visualstudio.com/api/working-with-extensions/publishing-extension#prerelease-extensions)).
- **JetBrains Plugins:**
  - JetBrains recommends SemVer in `<version>` inside `plugin.xml` ([JetBrains Marketplace SemVer Docs](https://plugins.jetbrains.com/docs/marketplace/semver.html)) and separates IDE compatibility into `<idea-version since-build="242" until-build="242.*"/>` ([Plugin Configuration File `plugin.xml`](https://plugins.jetbrains.com/docs/intellij/plugin-configuration-file.html), [Build Number Ranges](https://plugins.jetbrains.com/docs/intellij/build-number-ranges.html), [Plugin Compatibility](https://plugins.jetbrains.com/docs/intellij/plugin-compatibility.html)).
  - Only plugins that compile separate binary artifacts per IntelliJ platform branch due to internal JVM ABI breaks append the branch number (e.g., `1.5.0-242`).

### 1.8 Terraform Providers vs. Terraform Core
- Until 2017, Terraform bundled cloud providers inside the `terraform` CLI binary under a single version (`0.9.x`). In **Terraform 0.10** (June 2017), HashiCorp split providers into separately versioned binaries because cloud APIs (AWS, GCP, Azure) and the core HCL engine evolve at completely different velocities ([Upcoming Provider Changes in Terraform 0.10](https://www.hashicorp.com/blog/upcoming-provider-changes-in-terraform-0-10)).
- Today, compatibility is governed by three explicit contracts:
  1. `required_version` in the `terraform` block constraining the Terraform CLI (`>= 1.9.0`) ([Terraform Block Reference](https://developer.hashicorp.com/terraform/language/block/terraform), [Version Constraints](https://developer.hashicorp.com/terraform/language/expressions/version-constraints));
  2. `required_providers` constraining each provider (`hashicorp/aws ~> 5.0`) ([Provider Requirements](https://developer.hashicorp.com/terraform/language/providers/requirements)); and
  3. The wire-level gRPC **Terraform Plugin Protocol** (v5 / v6) negotiated at runtime between Core and Provider ([Terraform Plugin Protocol](https://developer.hashicorp.com/terraform/plugin/terraform-plugin-protocol)) — directly analogous to Flotilla's `WireProtocol` (`1...13`) and `HelperInterface` (`version = 5`).

### 1.9 Wine / CodeWeavers CrossOver vs. Valve Proton
The contrast between **CrossOver** and **Proton** directly illuminates the difference between a **standalone GUI product** and a **headless runtime drop-in**:
- **CodeWeavers CrossOver (`24.0.x` vs. Wine `9.0`):**
  - CrossOver is a commercial macOS/Linux/ChromeOS GUI application with bottle management, dependency installers ("CrossTies"), D3DMetal, DXVK, and MoltenVK. It versions itself on its own annual product cycle (**CrossOver `24.0.0`**, `24.0.5`) and states in its release notes which upstream Wine release it embeds (e.g., CrossOver 24 rebases onto **Wine 9.0**) ([CrossOver Changelog](https://www.codeweavers.com/crossover/changelog), [CrossOver 24 Release Blog](https://www.codeweavers.com/blog/mjohnson/2024/2/15/crossover-24-has-landed)).
- **Valve Proton (`Proton 9.0-3` vs. Wine `9.0`):**
  - Proton has no standalone GUI or independent product identity; it is a compatibility runner selected inside Steam's *"Force the use of a specific Steam Play compatibility tool"* dropdown. Therefore, Valve versions stable Proton builds as `Proton <Wine-major.minor>-<revision>` (`Proton 9.0-3`) alongside a rolling `Proton Experimental` branch ([`github.com/ValveSoftware/Proton`](https://github.com/ValveSoftware/Proton), [Proton Releases](https://github.com/ValveSoftware/Proton/releases), [Proton Changelog Wiki](https://github.com/ValveSoftware/Proton/wiki/Changelog)).

### 1.10 Proxmox VE vs. Debian and QEMU
- **Proxmox Virtual Environment (`8.2`, `8.3`):**
  - Proxmox VE is built on **Debian 12 (Bookworm)**, ships a custom Ubuntu-derived Linux kernel (`6.8`), and bundles **QEMU (`8.1` → `9.0`)**, **LXC (`6.0`)**, **ZFS (`2.2`)**, and **Ceph (`17.2` / `18.2`)** ([Proxmox VE Admin Guide](https://pve.proxmox.com/pve-docs/pve-admin-guide.html), [Proxmox VE Roadmap](https://pve.proxmox.com/wiki/Roadmap), [Proxmox VE Kernel Wiki](https://pve.proxmox.com/wiki/Proxmox_VE_Kernel)).
  - Proxmox VE does **not** version itself `12.x` after Debian or `9.x` after QEMU. Instead, its major version (`8.x`) represents the Proxmox cluster/API lifecycle contract (one major release per Debian stable generation: PVE 7 = Debian 11, PVE 8 = Debian 12), while minor releases (`8.1`, `8.2`, `8.3`) upgrade QEMU (e.g., QEMU `8.1` → `9.0` in PVE `8.2`) and the Linux kernel mid-stream.

### 1.11 Apple's Own Products (Xcode, Safari, and `apple/container` vs. `apple/containerization`)
1. **Xcode vs. SDKs and Swift:**
   - Historically, Xcode (`15.x`, `16.x`), macOS (`14.x`, `15.x`), and iOS (`17.x`, `18.x`) had three different major numbers; in 2025/2026 Apple aligned Xcode and its OS families to year-based major version **`26`** (`Xcode 26`, `macOS 26 Tahoe`, `iOS 26`) so developers can tell at a glance which annual OS SDK generation an Xcode release targets ([Xcode Support & SDK Matrix](https://developer.apple.com/support/xcode/)).
   - However, the **Swift compiler and toolchain (`Swift 6.0`, `6.2`, `6.3`)** bundled inside Xcode continues to version **completely independently** because Swift is a cross-platform language with its own evolution and source-compatibility guarantees.
2. **Safari vs. WebKit:**
   - Safari's user-facing `CFBundleShortVersionString` tracks the OS release (`18.x`, `26.x`) ([Safari Release Notes](https://developer.apple.com/documentation/safari-release-notes)), while its `CFBundleVersion` encodes the OS build prefix plus the underlying **WebKit** engine version (e.g., `20619.1.26.31.6` for WebKit `619.1.26`).
3. **Most Telling of All — Apple's Own `apple/container` (`1.5.0`) vs. `apple/containerization` (`0.52.0`):**
   - Apple's [`apple/container`](https://github.com/apple/container/releases) CLI is itself a high-level tool built on top of Apple's lower-level Swift framework [`apple/containerization`](https://github.com/apple/containerization/tags).
   - Does `apple/container` version itself `0.52.0.0` to match `apple/containerization`? **No.** In [`apple/container/Package.swift`](https://github.com/apple/container/blob/main/Package.swift), Apple versions the `container` CLI independently at **`1.5.0`** while pinning `let scVersion = "0.52.0"` (`apple/containerization`) and `let builderShimVersion = "0.13.2"` as dependencies.

### 1.12 GUI Front-Ends for CLI Tools (Git GUIs, Docker API GUIs, and Other `apple/container` GUIs)
- **Git GUI Clients vs. Git CLI (`2.4x` / `2.5x`):**
  - **Sourcetree (`4.2.x` macOS / `3.4.x` Windows):** Independent SemVer; lets users switch between **Embedded Git** and **System Git** in `Preferences > Git` ([Sourcetree Download Archives](https://www.sourcetreeapp.com/download-archives), [Atlassian Sourcetree Docs](https://support.atlassian.com/sourcetree/)).
  - **Tower (`18.x` macOS) & Fork (`2.x` macOS/Windows):** Independent product versions; bundle a baseline Git binary and offer a **Git Instance selector** in Preferences showing exact versions of `/usr/bin/git`, `/opt/homebrew/bin/git`, and bundled Git ([Tower Release Notes](https://www.git-tower.com/release-notes), [Fork Release Notes](https://git-fork.com/release-notes)).
  - **GitHub Desktop (`3.6.x`):** Independent SemVer ([GitHub Desktop Releases](https://github.com/desktop/desktop/releases)) embedding a dedicated native Git package [`desktop/dugite`](https://github.com/desktop/dugite/releases) (`v3.2.3`), which also versions itself independently and notes the embedded Git version in release notes.
  - **GitKraken Desktop (`10.x` / `11.x`):** Independent SemVer; transitioned from in-process `libgit2` to a bundled/system Git executable in `v9.5+` ([GitKraken Current Version](https://help.gitkraken.com/gitkraken-desktop/current-version/)).
- **Docker/Kubernetes API Front-Ends:**
  - **Portainer (`2.45.x LTS` / `2.39.x LTS`):** Independent SemVer with an explicit **Supported Versions & Compatibility Matrix** for Docker Engine, Swarm, and Kubernetes ([Portainer Releases](https://github.com/portainer/portainer/releases), [Portainer Requirements Matrix](https://docs.portainer.io/start/requirements-and-prerequisites)).
  - **Lazydocker (`v0.25.2`):** Independent `0.x.y` SemVer negotiating Docker API versions (`1.25`–`1.52+`) ([Lazydocker Releases](https://github.com/jesseduffield/lazydocker/releases), [Lazydocker Issue #580](https://github.com/jesseduffield/lazydocker/issues/580)).
- **Other Community GUIs for Apple `container`:**
  - **Orchard (`andrew-waters/orchard` — `v2.5.2`, ~1.7k stars):** Uses independent SemVer (`v2.5.2`) while linking `apple/container` (`minimumVersion = 1.5.0`) over XPC and stating in `CHANGELOG.md`: *"Orchard now builds against Apple container 1.5.0 (containerization 0.47.0), up from 1.4.1"* ([`github.com/andrew-waters/orchard`](https://github.com/andrew-waters/orchard), [Orchard Releases](https://github.com/andrew-waters/orchard/releases), [Orchard `CHANGELOG.md`](https://github.com/andrew-waters/orchard/blob/main/CHANGELOG.md)).
  - **ContainerManager (`duminga/ContainerManager` — `v1.0.0`):** Uses independent SemVer (`v1.0.0`) and declares `Requirements: Apple Container CLI 1.2.x installed` in its README ([`github.com/duminga/ContainerManager`](https://github.com/duminga/ContainerManager), [ContainerManager Releases](https://github.com/duminga/ContainerManager/releases)).
  - **AppleContainerDesktop (`0Itsuki0/AppleContainerDesktop` — `2.0.0` / `1.2.0`) & Others:** All use independent SemVer (`2.0.0`, `1.1.1`, `0.2.0`) and note target `container` versions in release notes and README callouts ([`0Itsuki0/AppleContainerDesktop/releases`](https://github.com/0Itsuki0/AppleContainerDesktop/releases), [`ducheharsh/apple-container-desktop/releases`](https://github.com/ducheharsh/apple-container-desktop/releases), [`FeSens/container-gui/releases`](https://github.com/FeSens/container-gui/releases)).

### 1.13 Synthesis of Prior Art: The Taxonomic Divide
Every project in our survey falls cleanly into one of two categories:

1. **1:1 Downstream Packagings of an Upstream Binary** (*Debian `.deb` packages, Homebrew formulae, K3s/RKE2, GKE, Valve Proton*):
   - The user is installing the package *in order to get that specific upstream version* (`k3s` *is* Kubernetes `1.30.2`; a Homebrew formula *is* `openssl 3.3.1`).
   - These projects use `<upstream-version><separator><packaging-revision>` (`1.5.0_1`, `1.5.0-1`, `v1.30.2+k3s1`, `9.0-3`) — and **never** use a 4th dot-separated integer (`.0`), because they keep the revision syntactically distinct (`_`, `-`, `+`) from upstream's version tuple.
2. **Independent Products That Drive, Wrap, or Orchestrate an Engine** (*Docker Desktop, Podman Desktop, Rancher Desktop, OrbStack, Colima, CrossOver, Proxmox VE, Electron, VS Code, Sourcetree/Tower/Fork, Portainer, Orchard, and `apple/container` itself*):
   - The product has its own UI, architecture, features, and release cadence, and may doesn't even bundle the engine (or drives multiple hosts/engine versions).
   - **100% of these products use independent version numbers** and communicate engine compatibility via UI, release notes, and runtime preflight checks.

**Inference:** Flotilla belongs unmistakably to Category 2. It does not even bundle `container` inside `Flotilla.app` (it downloads and installs Apple's signed `container-1.5.0-signed.pkg` separately via [`ContainerPackage.swift`](Sources/FlotillaCore/ContainerPackage.swift) or uses an existing installation), and it manages fleets of Macs that may run different `container` versions (`>= 1.0.0`).

---

## 2. Question 2: Mechanics on Apple Platforms & Sparkle

### 2.1 Official Apple Specifications for `CFBundleShortVersionString` and `CFBundleVersion`
Apple's documentation and Technical Note TN2420 define strict rules for both `Info.plist` keys:

- **[`CFBundleShortVersionString`](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleshortversionstring) (Marketing Version):**
  - *"This key is a user-visible string for the version of the bundle. The required format is **three period-separated integers**, such as 10.14.1. The string can only contain numeric characters (0-9) and periods."*
- **[`CFBundleVersion`](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion) (Build Version):**
  - *"This key is a machine-readable string composed of **one to three period-separated integers**, such as 10.14.1. The string can only contain numeric characters (0-9) and periods. You can include more integers but the system ignores them. You can also abbreviate the build version by using only one or two integers, where missing integers in the format are interpreted as zeros. For example, 0 specifies 0.0.0, 10 specifies 10.0.0, and 10.5 specifies 10.5.0."*
  - *"For macOS apps, increment the build version before you distribute a build."*
- **[Apple Technical Note TN2420 (*Version Numbers and Build Numbers*)](https://developer.apple.com/library/archive/technotes/tn2420/_index.html):**
  - *"Each integer value separated by a period is a component of the version. Version numbers and build numbers may have **up to three components** separated by periods."*
  - **Explicitly listed under "Illegal examples" in TN2420:** `a`, `1.a`, `1.10000.1.5` (a 4-component version is explicitly marked **Illegal**).
  - **Cross-Train Monotonicity on macOS:** *"However, for macOS apps, build numbers must monotonically increase even across different versions. In other words, for macOS apps you cannot use the same build numbers again in different release trains."* (Flotilla's `git rev-list --count HEAD` in `CFBundleVersion` satisfies this rule).

### 2.2 How Each Apple Subsystem Handles `1.5.0.0` and `1.5.0.0-beta.4`

#### 1. Mac App Store / App Store Connect
- **Result:** **Hard rejection (`ERROR ITMS-90060`).**
- App Store Connect validates `CFBundleShortVersionString` against `^\d+(\.\d+){0,2}$` (1–3 non-negative integers, max 18 chars) per [TN2420](https://developer.apple.com/library/archive/technotes/tn2420/_index.html). Both a 4th integer (`1.5.0.0`) and a pre-release suffix (`-beta.4`) trigger `ERROR ITMS-90060`. (While Flotilla distributes outside the App Store via Developer ID because of `Virtualization.framework` / `SMAppService` daemon requirements, violating TN2420 still impacts other macOS tools below.)

#### 2. Direct Distribution Notarization (`xcrun notarytool`) and Gatekeeper (`spctl`)
- **Result:** **Permitted.**
- Apple's Notary Service checks code signatures, Developer ID certificates, secure timestamps, Hardened Runtime, entitlements, and malware ([Notarizing macOS Software Before Distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [Resolving Common Notarization Issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)). It does not enforce TN2420 syntax on `CFBundleShortVersionString`.

#### 3. LaunchServices (`lsd` / `lsregister`) and `SMAppService`
- **Result:** **Uses `CFBundleVersion` only (ignores `CFBundleShortVersionString` and ignores >3 components).**
- Per Apple's [Launch Services Concepts — Preferred Applications](https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/LaunchServicesConcepts/LSCConcepts/LSCConcepts.html) (Criterion 4e): *"If two or more versions of the same application have been found, give preference to the one with the latest version number as identified by `CFBundleVersion`."*
- Inspecting `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump` on macOS confirms that every bundle record's 32-byte `LSVersionNumber` (`version:`) is parsed from **`CFBundleVersion`** (at most 3 integers; e.g., `CFBundleVersion = 422` → `version: 422.0`), never from `CFBundleShortVersionString`. Likewise, [`SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice) (`backgroundtaskmanagementd`) tracks embedded `FlotillaHelper` launch daemons across updates via `CFBundleVersion`.

#### 4. Apple's `/usr/sbin/installer` (`pkgbuild` / `productbuild` / `PackageKit.framework`)
- **Result:** **Both `-beta.N` suffixes and 4-component version tuples break or are silently truncated inside `PackageKit.framework`!**
- We inspected both [`pkgbuild(1)`](https://keith.github.io/xcode-man-pages/pkgbuild.1.html) and `/System/Library/PrivateFrameworks/PackageKit.framework`:
  1. **Package-level `--version` (`-[PKComponent versionCompare:]`):**
     - `PKComponent` compares the `--version` attribute on `<pkg-ref>` using `-[NSString compare:options:NSNumericSearch]`.
     - Under `NSNumericSearch`, `"1.5.0-beta.2"` vs `"1.5.0"` matches the shared `"1.5.0"` prefix and sees remaining characters `"-beta.2"` on the beta string, returning **`NSOrderedDescending` (`1.5.0-beta.2 > 1.5.0`)**! That is why on 5 October 2026 ([`DECISIONS.md:564-575`](DECISIONS.md#L564-L575)), [`Scripts/make-pkg.sh:70-76`](Scripts/make-pkg.sh#L70-L76) had to be changed to pass `$PKG_VERSION` (the integer git commit count) to `pkgbuild --version`.
  2. **Bundle-level version check (`BundleIsVersionChecked` / `PKBundleComponentVersion`):**
     - By default (`BundleIsVersionChecked = true`), `pkgbuild` embeds `<bundle-version>` in `PackageInfo` containing the app's `CFBundleShortVersionString` and `CFBundleVersion`.
     - At install time, `-[PKBundleComponentVersion compare:]` normalizes each version field via `+[PKBundleComponentVersion _standardizedTupleVersionString:]`, which splits on `"."`, **loops at most 3 times** (`cmp x25, #0x3`), takes `-[NSString intValue]` of each segment, and formats `"%u.%u.%u"`:
       - **The 4th component is silently discarded:** `"1.5.0.0"`, `"1.5.0.1"`, and `"1.5.0.99"` all normalize to **`"1.5.0"`**!
       - **`-beta.N` on a 3-part or 4-part version is silently discarded:** `"1.5.0-beta.4"` splits into `["1", "5", "0-beta", "4"]`; the first three `intValue`s are `1`, `5`, `0` (`"0-beta".intValue == 0`), normalizing to **`"1.5.0"`**.
       - **`-beta.N` on a 2-part version corrupts the 3rd integer:** `"1.5-beta.4"` splits into `["1", "5-beta", "4"]`, whose `intValue`s are `1`, `5`, `4` → **`"1.5.4"`** (making `1.5-beta.4` look newer than `1.5.0` through `1.5.3`!).
     - Because `PKBundleComponentVersion` checks `CFBundleShortVersionString` first and `CFBundleVersion` second, having `"1.5.0.0-beta.4"`, `"1.5.0.0"`, and `"1.5.0"` all normalize to `"1.5.0"` in the first check means `installer` falls through to comparing `CFBundleVersion` (`422.0.0` vs `566.0.0`), which succeeds **only** because `CFBundleVersion` is a monotonic integer.

#### 5. `softwareupdate(8)`
- **Result:** **Not applicable.**
- Per [`softwareupdate(8)`](https://support.apple.com/guide/deployment/use-command-line-tools-depc4c80847a/web), `/usr/sbin/softwareupdate` only manages Apple system software updates and never inspects third-party app bundles.

#### 6. macOS MDM (`InstalledApplicationList`) and Jamf Pro (Planned for Flotilla 2.0)
- **macOS MDM [`InstalledApplicationList`](https://developer.apple.com/documentation/devicemanagement/installedapplicationlistresponse/installedapplicationlistitem):**
  - Reports `ShortVersion` (`CFBundleShortVersionString`) and `Version` (`CFBundleVersion`) as strings to the MDM server.
- **Jamf Pro Inventory, Smart Groups, and Patch Management:**
  - Jamf Pro collects `Application Version` / `Application Bundle Short Version` (`CFBundleShortVersionString`) and `Application Bundle Version` (`CFBundleVersion`, added as an explicit Smart Group criterion in Jamf Pro 11.23.0) ([Jamf Pro Applications Category Docs](https://learn.jamf.com/r/en-US/jamf-pro-documentation-11.17.0/Applications_Category?contentId=O8Mb~DCRBDjYh5Lusmsiaw), [Jamf 11.23 Smart Group Criteria](https://grahamrpugh.com/2025/12/02/new-smart-group-criteria.html)).
  - In **Jamf Pro Patch Management** ([Patch Definitions Docs](https://learn.jamf.com/r/en-US/title-editor/Patch_Definitions?contentId=G86W~KJvl6vjTmgJpsmtDw), [Creating a Patch Policy](https://learn.jamf.com/r/en-US/jamf-pro-documentation-11.30.0/Creating_a_Patch_Policy?contentId=sKlT0cEguK_G_u9gI3lH9Q)), client versions are matched against defined versions by `CFBundleShortVersionString`. Unlisted pre-release strings (`1.5.0.0-beta.4`) or non-standard 4-part strings are bucketed as **`Unknown Version`**, and regex generators (`VersionRegexGenerator`) used by Jamf admins assume standard 3-part `MAJOR.MINOR.PATCH` versions.

### 2.3 How Sparkle 2 Compares Versions and What It Recommends
We verified Sparkle 2's behavior directly against its official documentation and `2.x` source code:

1. **Sparkle Compares `<sparkle:version>` against `CFBundleVersion` Exclusively:**
   - In [`SUHost.m` (lines 166–189)](https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SUHost.m) and [`SUAppcastItem.m` (lines 458–503)](https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SUAppcastItem.m), `_host.version` reads `CFBundleVersion` and `ui.versionString` reads `<sparkle:version>`.
   - In [`SUAppcastDriver.m` (line 567)](https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SUAppcastDriver.m), update eligibility is:
     ```objc
     [[self versionComparator] compareVersion:_host.version toVersion:ui.versionString] == NSOrderedAscending
     ```
   - `CFBundleShortVersionString` and `<sparkle:shortVersionString>` are **never** passed to `SUStandardVersionComparator`; they are only formatted for the UI by [`SPUStandardVersionDisplay.m`](https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SPUStandardVersionDisplay.m).
2. **The Hyphen (`-`) Rule in [`SUStandardVersionComparator.m`](https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SUStandardVersionComparator.m):**
   - In `splitVersionString:` (lines 84–91 of [`SUStandardVersionComparator.m`](https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SUStandardVersionComparator.m)), when Sparkle's comparator encounters a hyphen (`kDashType`), **it immediately `break`s out of the loop and discards the `-` and everything after it** (because Sparkle treats `-` as a git commit SHA suffix like `1.5.5-335d3e2`, verified in [`SUVersionComparisonTest.m`](https://github.com/sparkle-project/Sparkle/blob/2.x/Tests/SUVersionComparisonTest.m)).
   - **Critical implication:** If Flotilla ever put SemVer strings with `-beta.N` into `CFBundleVersion` / `<sparkle:version>`, Sparkle would truncate `"1.5.0-beta.2"`, `"1.5.0-beta.4"`, and `"1.5.0"` all to `"1.5.0"` and consider them **equal (`NSOrderedSame`)**!
   - Because Flotilla puts the monotonic git commit count (`347`, `392`, `422`) in `CFBundleVersion` and `<sparkle:version>`, `SUStandardVersionComparator` compares them as single `kNumberType` tokens via 64-bit `[partA longLongValue]` vs `[partB longLongValue]`, which is 100% immune to `CFBundleShortVersionString` format changes.
3. **Sparkle's Official Recommendation:**
   - [Sparkle Documentation — Publishing an Update (`#internal-build-numbers` & `#channels`)](https://sparkle-project.org/documentation/publishing/) explicitly recommends putting a simple machine-readable build integer (e.g., `1248`) in `CFBundleVersion` / `<sparkle:version>` and a clean human-readable marketing version (e.g., `1.5.1`) in `CFBundleShortVersionString` / `<sparkle:shortVersionString>`.

---

## 3. Question 3: Semantics for Users & The Roadmap Conflict

### 3.1 What a Version Number Promises to Users
To a macOS user, developer, or IT administrator, an application's version number (`Flotilla X.Y.Z`) communicates three things ([SemVer 2.0.0](https://semver.org/)):
1. **Identity & Ownership:** The number belongs to *Flotilla* and measures Flotilla's maturity and feature set.
2. **Magnitude of Change:**
   - **Major (`X`):** Architectural shifts, major product milestones, or breaking workflow/configuration changes.
   - **Minor (`Y`):** New user-visible features (e.g., Greta, fleet groups, Finder file browser, image transfer).
   - **Patch (`Z`):** Bug fixes, security patches, or updated runtime support.
3. **Legibility:** A 3-part number (`1.5.0`) is instantly recognizable. A 4-part number (`1.5.0.0`) looks like a typo (`1.5.0` with a stray `.0`), a Windows `AssemblyFileVersion`, or a printer driver build number.

### 3.2 The Explicit Conflict with Flotilla's Own Roadmap
In the repository today, **Flotilla's own engineering documents already reject the `<container version>.<Flotilla revision>` mental model in how they talk about the roadmap**:

- **[`DECISIONS.md` Q47 (10 October 2026, lines 2226–2243)](DECISIONS.md#L2226-L2243):**
  > *"Cross-Mac networking and MDM are **2.0**; a fleet ledger comes first... 1. D4 is deferred to **2.0**... 2. **2.0** starts with trust, not a tunnel... 3. Jamf/MDM support is **2.0**... 4. Flotilla Web and the iPad app are **2.0**."*
- **[`DECISIONS.md` Q44 Amended (10 October 2026, line 2245)](DECISIONS.md#L2245):**
  > *"The owner kept the time-bounded keep-awake request in **1.5**, and moved Runtime Saver to **2.0**."*
- **[`DECISIONS.md` Q52 (16 October 2026, lines 2367–2375)](DECISIONS.md#L2367-L2375):**
  > *"Greta... 1. It is in **1.5**, off by default... 3. On-device only in **1.5**... Apple's Private Cloud Compute model (32K context, stronger reasoning) is **2.0**."*
- **[`PLAN.md` (10 October 2026, lines 797–841)](PLAN.md#L797-L841):**
  > Dedicated top-level section titled **`## Version 2.0 (the owner, 10 October)`** listing the Fleet Ledger, Cross-Mac Networking, Runtime Saver, Jamf/MDM, and Flotilla Web & iPad.
- **[`research/MIGRATION-HA.md` (line 3)](research/MIGRATION-HA.md#L3):**
  > *"for the **1.5** manual migration and the **2.0** high-availability idea."*

None of those features (Greta, Fleet Ledger, Cross-Mac Tunnels, Jamf/MDM, Flotilla Web, iPad app) live in Apple's `container` CLI. They are 100% Flotilla features.

### 3.3 Concrete Failure Modes If Flotilla Keeps `<container version>.<Flotilla revision>`

1. **Scenario A — Flotilla Ships a Major Milestone While `container` Stays at `1.5.0`:**
   - Suppose Flotilla finishes the Fleet Ledger, Cross-Mac Tunnels, High Availability, and the iPad companion app ("Version 2.0" in `PLAN.md`), while Apple's `container` is still at `1.5.0` or `1.5.1`.
   - Under `<container version>.<Flotilla revision>`, Flotilla's biggest architectural release in its history must be named **`Flotilla 1.5.0.8`** — burying a major release in the **fourth** digit!
   - Even for minor feature releases (e.g., shipping a major Greta upgrade or Finder file browser two weeks after `1.5.0.0`), bumping from `1.5.0.0` to `1.5.0.1` looks to every user like a tiny hotfix to a patch release.
2. **Scenario B — Apple Ships `container 2.0.0` While Flotilla Changes Almost Nothing:**
   - Suppose Apple bumps `apple/container` from `1.5.0` to `2.0.0` because Apple removed a deprecated CLI flag or refactored its internal XPC schema, and Flotilla only needs a 10-line compatibility tweak in `ContainerRuntime.expectedVersion`.
   - Under the current scheme, Flotilla is forced to call that maintenance update **`Flotilla 2.0.0.0`** — burning the `"2.0"` product version number before any of `PLAN.md`'s Version 2.0 features exist, and confusing every user who reads the roadmap.
3. **Scenario C — Apple Ships `container 1.5.1` on the Same Day Flotilla Has Unfinished 1.5 Work:**
   - Because the 4th component resets whenever Apple moves (`1.5.0.4` → `1.5.1.0`), Flotilla's revision counter constantly loses continuity, and users cannot tell whether `1.5.1.0` contains new Flotilla features or merely bumps `ContainerRuntime.expectedVersion`.
4. **Scenario D — Multi-Host Fleets Do Not Have a Single `container` Version:**
   - Flotilla supports any local or remote Mac running `container >= 1.0.0` ([`Preflight.defaultMinimumVersion`](Sources/FlotillaCore/Preflight.swift#L18)). An admin Mac running Flotilla may simultaneously manage Host A on `container 1.5.0`, Host B on `container 1.4.1`, and Host C on `container 1.3.1`. Baking `1.5.0` into Flotilla's own version number falsely implies lockstep 1:1 coupling.

---

## 4. Question 4: Evaluation of Alternatives

We evaluate all five alternatives across user clarity, compatibility communication, ordering mechanics (Sparkle, `installer`, Host Self-Update, Jamf/MDM), and migration from `1.5.0.0-beta.4` (build `422`).

### Option 1: Independent 3-Part SemVer (`1.5.0`) + Stated `container` Compatibility *(Recommended)*
- **Format:** `MAJOR.MINOR.PATCH` (`1.5.0-beta.5` → `1.5.0` → `1.5.1` → `1.6.0` → `2.0.0`), with `CFBundleVersion` remaining the monotonic git commit count (`566+`).
- **Why Start at `1.5.0` (Not `1.0.0`):**
  1. Existing beta users and tags are already on the `1.5.0.x` train (`v1.5.0.0-beta.2` through `v1.5.0.0-beta.4`), so moving from `1.5.0.0-beta.4` to `1.5.0-beta.5` / `1.5.0` is monotonically forward or equal in every human and machine reading.
  2. All current roadmap documents ([`DECISIONS.md`](DECISIONS.md#L2226-L2378), [`PLAN.md`](PLAN.md#L797)) already refer to the current release as **`1.5`** and the next major architecture as **`2.0`**. Starting independent SemVer at `1.5.0` preserves 100% of that terminology without changing a single roadmap reference.
- **How Compatibility Is Communicated:**
  - **About Window ([`AboutView.swift`](Sources/Flotilla/AboutView.swift#L27-L44)):** Already displays `Version 1.5.0 (566)` on the first line and `Apple container 1.5.0 · Catalog 2026.10.12.0` directly beneath it! We can optionally clarify this line to `Apple container 1.5.0 (target 1.5.0, min 1.0.0)` when a different runtime version is installed.
  - **Window Status Bar ([`WindowStatusBar.swift:93-155`](Sources/Flotilla/WindowStatusBar.swift#L93-L155)) & Hosts View ([`HostsView.swift:83-102`](Sources/Flotilla/HostsView.swift#L83-L102)):** Already compare each host's installed `container` version against [`ContainerRuntime.expectedVersion`](Sources/FlotillaCore/ContainerPackage.swift#L10) (`"1.5.0"`) and show an amber update pill when `container < 1.5.0`.
  - **Release Notes ([`Scripts/publish-release.sh`](Scripts/publish-release.sh)):** Include a standard line in the release notes header and Sparkle `<description>`: `Target runtime: Apple container 1.5.0 (requires container ≥ 1.0.0)`.
  - **Update Check (Sparkle):** Compares `CFBundleVersion` (`566 > 422`); after update, Flotilla's existing runtime check ([`AppModelRuntimeSetup.swift`](Sources/Flotilla/AppModelRuntimeSetup.swift)) prompts to install/upgrade `container` if `ContainerRuntime.expectedVersion` moved.
  - **Host-Update Wire Check:** Wire `Hello` / `HostStatusSnapshot` continues sending `"1.5.0 (566)"` for `flotillaVersion`, `"1.5.0"` for `containerVersion`, and `WireProtocol.supportedVersions` (`1...13`). And removing the 4th component **fixes** [`SoftwareVersion`](Sources/FlotillaCore/Fleet/VersionSkew.swift#L29-L33) so `1.5.0` vs `1.5.1` compares properly even without build numbers!
- **Pros:**
  - 100% compliant with [SemVer 2.0.0](https://semver.org/) and Apple [TN2420](https://developer.apple.com/library/archive/technotes/tn2420/_index.html) (for stable releases).
  - Aligns with Docker Desktop, Podman Desktop, Rancher Desktop, OrbStack, CrossOver, Tower, Fork, Orchard, and `apple/container` itself.
  - Eliminates the roadmap conflict (`1.5` = current release with Greta; `1.6` = next feature release; `2.0` = Fleet Ledger / HA / MDM / Web & iPad).
  - Works out of the box with [`SoftwareVersion`](Sources/FlotillaCore/Fleet/VersionSkew.swift), [`VersionTriple`](Sources/FlotillaCore/Preflight.swift), `PackageKit`, and Jamf Pro.
- **Cons:**
  - A user looking *only* at the filename `Flotilla-1.6.0.dmg` won't see the target `container` version in the filename (solved by stating `Target runtime: Apple container 1.5.0` in release notes, About, and onboarding — which Flotilla already automates via one-click runtime install).

### Option 2: Calendar Versioning (`YYYY.M.D` or `YYYY.MM.DD.N`, like `SuggestionLibrary`)
- **Format:** `2026.10.19` (3-part `YYYY.M.D` to fit Apple's 3-integer limit) or `2026.10.19.0` (4-part, matching [`SuggestionLibrary`](Sources/FlotillaCore/SuggestionLibrary.swift)).
- **Why It Works for `SuggestionLibrary` Today:**
  - `SuggestionLibrary` (`2026.10.12.0`) is a **data feed** updated continuously as new container images and CVE advisories are scanned. A date version tells the user *how fresh the catalog data is*, while breaking format changes are handled separately by `SuggestionLibrary.currentSchema = 2`.
- **Why It Fails for `Flotilla.app`:**
  1. **Destroys the `1.5` / `2.0` Roadmap:** You cannot say "Greta is in 1.5" or "Fleet Ledger is 2.0" if the app is named `Flotilla 2026.10.19`.
  2. **Leading-Zero Trap:** Standard CalVer `YYYY.0M.0D` (`2026.03.05`) violates [SemVer 2.0.0 Rule 2](https://semver.org/#spec-item-2) and Apple's integer normalization (which is why Docker Engine abandoned `YY.0M` CalVer in 23.0: [Docker Engine 23.0 Release Notes](https://docs.docker.com/engine/release-notes/23.0/)).
  3. **3-Integer Limit vs. Same-Day Hotfixes:** Under Apple's 3-integer `CFBundleShortVersionString` limit (`YYYY.M.D`), if you ship two releases on the same day, there is no 4th slot (`N`) for a revision without violating TN2420 and having `PKBundleComponentVersion` silently drop `.N`.
  4. **No Signal of Breaking vs. Trivial Changes:** A massive architectural rewrite and a typo fix one day later look identical (`2026.11.1` vs `2026.11.2`).

### Option 3: SemVer + Build Metadata (`1.5.0+container.1.5.0` or `1.5.0+1.5.0`)
- **Format:** `1.5.0+container.1.5.0` (or `1.5.0-beta.5+container.1.5.0`).
- **Pros:**
  - Valid [SemVer 2.0.0 Rule 10](https://semver.org/#spec-item-10) syntax.
  - Encodes both Flotilla's SemVer (`1.5.0`) and the target `container` version (`+container.1.5.0`) in one string.
- **Cons (Fatal on Apple Platforms & in SemVer Precedence):**
  1. **Violates Apple TN2420 & Corrupts `CFBundleShortVersionString`:** `+container.1.5.0` contains `+` and letters and exceeds 18 characters (`1.5.0+container.1.5.0` is 21 chars; TN2420 max is 18 chars).
  2. **Breaks `SUStandardVersionComparator` if ever compared:** In [`SUStandardVersionComparator.m`](https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SUStandardVersionComparator.m), `+` is tokenized as `kPunctuationSeparatorType` (not ignored like in SemVer 2.0.0!).
  3. **Ignored by SemVer Precedence (The K3s Trap):** Under [SemVer 2.0.0 Rule 10](https://semver.org/#spec-item-10) (and Flotilla's own [`SemanticVersion.swift:59`](Sources/FlotillaCore/SemanticVersion.swift#L59), which strips everything after `+`), `1.5.0+container.1.5.0 == 1.5.0+container.1.5.1`. If Flotilla ships a rebuild solely to support a new `container` patch without bumping Flotilla's `1.5.0` prefix, SemVer parsers treat the two versions as identical.
  4. **Clutters UI and Filenames:** `Flotilla-1.5.0+container.1.5.0.dmg` (with `+` URL-encoded to `%2B` in GitHub Release asset URLs!) is awkward and error-prone.

### Option 4: Keep Current 4-Part Tracking Scheme (`<container version>.<Flotilla revision>`, `1.5.0.0`)
- **Format:** `1.5.0.0-beta.4` → `1.5.0.0` → `1.5.0.1` (resets to `1.5.1.0` when `container` ships `1.5.1`).
- **Pros:**
  - Already implemented in [`Scripts/make-app.sh`](Scripts/make-app.sh) and [`Scripts/release.sh`](Scripts/release.sh).
  - Tells a technical user who already knows the rule which `container` release Flotilla was tested against.
- **Cons:**
  - Violates [SemVer 2.0.0 Rule 2](https://semver.org/#spec-item-2) and [Apple TN2420](https://developer.apple.com/library/archive/technotes/tn2420/_index.html) (explicitly marked Illegal).
  - Silently truncated to 3 integers (`1.5.0`) by Apple's `PKBundleComponentVersion` in `/usr/sbin/installer` and by Flotilla's own [`SoftwareVersion`](Sources/FlotillaCore/Fleet/VersionSkew.swift#L29-L33) in `VersionSkew.swift`.
  - Directly contradicts Flotilla's own `1.5` and `2.0` roadmap in `DECISIONS.md` and `PLAN.md`.
  - Forces Flotilla to either bury major product releases in the 4th digit (`1.5.0.8`) or let Apple's CLI bumps hijack Flotilla's major version (`2.0.0.0`).
  - Built for an `UpdateCheck` mechanism that was deleted on 8 October 2026.

### Option 5: Hybrids
We consider two possible hybrid designs:
- **Hybrid 5a — Independent 3-Part SemVer (`1.5.0`) in `CFBundleShortVersionString`, Tags, and Filenames + Runtime Metadata in `Info.plist` (`FLTargetContainerVersion = 1.5.0`) and UI:**
  - Identical to **Option 1**, with an explicit `FLTargetContainerVersion` key in `Info.plist` (stamped from [`ContainerRuntime.expectedVersion`](Sources/FlotillaCore/ContainerPackage.swift#L10)) so support bundles, MDM custom attributes, and external scripts can inspect the target `container` version from `Info.plist` without polluting `CFBundleShortVersionString`.
- **Hybrid 5b — 3-Part Lockstep `<container major.minor>.<Flotilla revision>` (e.g., `1.5.0`, `1.5.1`, where `1.5` tracks `container 1.5.x` and `.0`/`.1` is Flotilla's revision):**
  - **Pros:** Fits into 3 integers (`X.Y.Z`), satisfying TN2420 and `PackageKit`.
  - **Cons:** Still suffers from the exact same semantic and roadmap collisions as Option 4! If `container` ships `1.5.1`, Flotilla cannot reflect `.1` without colliding with its own patch counter; if `container` stays at `1.5` when Flotilla ships its 2.0 architecture, Flotilla is stuck on `1.5.x`; if `container` jumps to `2.0`, Flotilla's `2.0` is hijacked.

### 4.1 Comprehensive Comparison Matrix Across All 5 Options

| Dimension | Option 1 / Hybrid 5a: Independent SemVer (`1.5.0`) **[Recommended]** | Option 2: CalVer (`2026.10.19`) | Option 3: SemVer + Build Metadata (`1.5.0+container.1.5.0`) | Option 4: Current 4-Part Tracking (`1.5.0.0`) | Hybrid 5b: 3-Part Lockstep (`<c.maj>.<c.min>.<rev>`) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **SemVer 2.0.0 Valid?** | **Yes** | Yes (if no leading zeroes) | Yes (but `+` ignored in ordering!) | **No** (4 numeric parts invalid) | Syntactically yes, semantically no |
| **Apple TN2420 Valid?** | **Yes** (on stable `1.5.0`) | **Yes** (if 3-part `YYYY.M.D`) | **No** (`+`, letters, >18 chars) | **No** (4 parts explicitly illegal) | **Yes** |
| **Roadmap Alignment (`1.5` Greta, `2.0` HA/MDM)?** | **Exact match** | **Broken** (no `1.5` or `2.0`) | **Exact match** | **Broken** (tied to `container`) | **Broken** (tied to `container`) |
| **About Dialog Communication** | `Version 1.5.0 (566)` + `Apple container 1.5.0` | `Version 2026.10.19 (566)` + `Apple container 1.5.0` | Redundant / cluttered string | `Version 1.5.0.0 (566)` + `Apple container 1.5.0` (redundant) | Ambiguous if `container` is `1.5.2` |
| **Sparkle Ordering (`CFBundleVersion`)** | **Works** (`422` → `566+`) | **Works** (`422` → `566+`) | **Works** (`422` → `566+`) | **Works** (`422` → `566+`) | **Works** (`422` → `566+`) |
| **Apple `installer` (`pkgbuild` & `PKBundleComponentVersion`)** | **Works** (all 3 parts preserved + `CFBundleVersion`) | **Works** (if 3-part; 4th part dropped) | **Truncated** at `+` | **4th part silently dropped** (`1.5.0.9` → `1.5.0`) | **Works** |
| **Host Self-Update & `VersionSkew.swift`** | **Works** (`SoftwareVersion` compares all 3 parts + build) | **Works** (if 3-part) | `+` ignored | **`SoftwareVersion` ignores 4th part!** | **Works** |
| **Jamf Pro / MDM (2.0)** | **Clean 3-part version** | Unconventional for macOS desktop apps | **Breaks Jamf regexes & patch defs** | **Non-standard 4-part string** | Clean 3-part version |
| **Migration from `1.5.0.0-beta.4` (build `422`)** | **Zero friction** (`1.5.0-beta.5` / `1.5.0`, build `566+`) | Jarring jump from `1.5.0.0` to `2026.10.x` | URL/filename encoding issues (`%2B`) | No change | Confusing when `container` ships `1.5.1` |

---

## 5. Question 5: Verdict & Concrete Migration Plan

### 5.1 Verdict
1. **Was the current scheme understandable when created?** Yes — on 12 September 2026, Flotilla was a local GUI wrapper with no Sparkle updater, no remote hosts, no helper daemon, and no 2.0 roadmap.
2. **Is it suitable or a good idea today?** **No.** Its original technical caller (`UpdateCheck`) no longer exists; its 4th component violates Apple's TN2420 specification and is silently ignored by both Apple's `PackageKit` and Flotilla's own [`VersionSkew`](Sources/FlotillaCore/Fleet/VersionSkew.swift#L29-L33); and it puts Flotilla's version number on a collision course with its own `1.5` and `2.0` product roadmap.
3. **When should Flotilla change it?** **Now — before shipping `1.5` final.**
   - Right now, only three beta tags exist on `gh-pages:appcast.xml` (`v1.5.0.0-beta.2`, `v1.5.0.0-beta.3`, `v1.5.0.0-beta.4`), and **zero stable releases** have been published.
   - Dropping the fourth component now means Flotilla's very first stable release will be cleanly named **`Flotilla 1.5.0`** instead of cementing `1.5.0.0` into stable tags, Homebrew casks, documentation, and user expectations.

### 5.2 Exact Next Version Strings
| Milestone | Git Tag | `CFBundleShortVersionString` | `CFBundleVersion` (`<sparkle:version>`) | Target `container` ([`ContainerRuntime.expectedVersion`](Sources/FlotillaCore/ContainerPackage.swift#L10)) |
| :--- | :--- | :--- | :--- | :--- |
| Current public beta | `v1.5.0.0-beta.4` | `1.5.0.0-beta.4` | `422` | `1.5.0` |
| **Next beta build** | **`v1.5.0-beta.5`** | **`1.5.0-beta.5`** | **`566+`** (`git rev-list --count HEAD`) | `1.5.0` |
| **Release candidate (if any)** | **`v1.5.0-rc.1`** | **`1.5.0-rc.1`** | **`580+`** | `1.5.0` |
| **First stable 1.5 release** | **`v1.5.0`** | **`1.5.0`** | **`600+`** | `1.5.0` |
| Bug-fix release or `container 1.5.1` bump | **`v1.5.1`** | **`1.5.1`** | **`620+`** | `1.5.0` or `1.5.1` |
| Next minor feature release | **`v1.6.0`** | **`1.6.0`** | **`700+`** | `1.5.x` or `1.6.x` |
| Fleet Ledger / Tunnels / MDM / Web & iPad | **`v2.0.0`** | **`v2.0.0`** | **`1000+`** | Whatever `container` is current |

### 5.3 Proof That Migrating from `1.5.0.0-beta.4` to `1.5.0-beta.5` / `1.5.0` Will Not Break Existing Beta Users
We verified every single update and comparison path for a user upgrading from installed `1.5.0.0-beta.4` (build `422`) to `1.5.0-beta.5` or `1.5.0` (build `566+`):

1. **Sparkle In-App Update (`AppUpdater.swift` + `SUAppcastDriver.m`):**
   - Installed app has `CFBundleVersion = 422`.
   - New appcast item has `<sparkle:version>566</sparkle:version>` and `<sparkle:shortVersionString>1.5.0-beta.5</sparkle:shortVersionString>` (or `1.5.0`).
   - `SUStandardVersionComparator` compares `"422"` vs `"566"` → `422 < 566` (`NSOrderedAscending`). Sparkle prompts: *"A new version of Flotilla is available! Flotilla 1.5.0-beta.5 is now available—you have 1.5.0.0-beta.4."* **Zero issues.**
2. **Apple `/usr/sbin/installer` (`.pkg` Upgrade):**
   - Package-level `--version`: `422` vs `566` (`NSNumericSearch` → `422 < 566`).
   - Bundle-level `PKBundleComponentVersion`: `_standardizedTupleVersionString("1.5.0.0-beta.4")` → `"1.5.0"` and `_standardizedTupleVersionString("1.5.0-beta.5")` / `"1.5.0"` → `"1.5.0"` (`NSOrderedSame`), so `PKBundleComponentVersion` falls through to `CFBundleVersion` (`"422.0.0"` vs `"566.0.0"` → `NSOrderedAscending`). **Zero issues.**
3. **Remote Host Self-Update (`FleetUpdate.swift`, `SelfUpdate.swift`, `FlotillaHelper/main.swift`):**
   - `FleetUpdate.isOutdated` parses `(422)` vs `(566)` → `422 < 566 == true`.
   - `SelfUpdate.prepare` and `FlotillaHelper.installFlotillaUpdate` check `newBuild (566) > ownBuild (422)`. **Zero issues.**
4. **Fleet `VersionSkew.compare` (`VersionSkew.swift`):**
   - `SoftwareVersion(parsing: "1.5.0.0-beta.4 (422)")` and `SoftwareVersion(parsing: "1.5.0-beta.5 (566)")` both parse `(major: 1, minor: 5, patch: 0)` and tie-break on `build: 422 < 566` → `.older`. And for future releases (`1.5.0` vs `1.5.1`), `SoftwareVersion` will now accurately see `patch: 0 < 1` even without build numbers!
5. **LaunchServices & `SMAppService` (`FlotillaHelper` Daemon Registration):**
   - Compares `CFBundleVersion` (`422.0` vs `566.0`). **Zero issues.**

### 5.4 Step-by-Step Implementation Checklist (When Ready to Execute)
When the team is ready to apply this change, only 5 places in the repo need updating:
1. **[`Scripts/release.sh`](Scripts/release.sh#L4-L40):** Update the usage comment and regex from `^v[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?(-(alpha|beta|rc)\.[0-9]+)?$` to strictly 3-part SemVer `^v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$`.
2. **[`Scripts/make-app.sh`](Scripts/make-app.sh#L109-L157):**
   - Remove the 4-component `case` patterns (`[0-9]*.[0-9]*.[0-9]*.[0-9]*`).
   - Fix the `+$SINCE_TAG` order of operations (validate the base tag with `case` *before* appending `+${SINCE_TAG}`, or keep `+${SINCE_TAG}` only in `FLGitDescribe` so `CFBundleShortVersionString` never contains `+`).
   - Optionally stamp `FLTargetContainerVersion` (`1.5.0`) into `Info.plist`.
3. **[`Sources/FlotillaCore/SemanticVersion.swift`](Sources/FlotillaCore/SemanticVersion.swift) & [`VersionSkew.swift`](Sources/FlotillaCore/Fleet/VersionSkew.swift) & [`Preflight.swift`](Sources/FlotillaCore/Preflight.swift):**
   - Remove dead `.revision` and `.runtimeComponents` from `SemanticVersion` (keeping backward-compatible parsing in `SoftwareVersion` so any old `1.5.0.0-beta.4` string is still accepted) and consolidate the three redundant version structs.
4. **[`RELEASING.md`](RELEASING.md#L144-L215) & [`DECISIONS.md`](DECISIONS.md#L509-L575):**
   - Record an amendment superseding the 12 September 2026 four-component scheme with 3-part independent SemVer (`1.5.0-beta.5` → `1.5.0`).
5. **[`Scripts/publish-release.sh`](Scripts/publish-release.sh):**
   - Include `Target runtime: Apple container <ContainerRuntime.expectedVersion>` in the generated release notes and appcast `<description>`.

---

## 6. Complete Bibliography of Primary Sources Cited

### Apple Developer Documentation, Tech Notes & Man Pages
- `CFBundleShortVersionString` Documentation: https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleshortversionstring
- `CFBundleVersion` Documentation: https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion
- Technical Note TN2420 (*Version Numbers and Build Numbers*): https://developer.apple.com/library/archive/technotes/tn2420/_index.html
- Launch Services Concepts (*Preferred Applications*): https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/LaunchServicesConcepts/LSCConcepts/LSCConcepts.html
- `SMAppService` Documentation: https://developer.apple.com/documentation/servicemanagement/smappservice
- Notarizing macOS Software Before Distribution: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Resolving Common Notarization Issues: https://developer.apple.com/documentation/security/resolving-common-notarization-issues
- MDM `InstalledApplicationListResponse.InstalledApplicationListItem`: https://developer.apple.com/documentation/devicemanagement/installedapplicationlistresponse/installedapplicationlistitem
- Apple Deployment Guide (`softwareupdate` & CLI tools): https://support.apple.com/guide/deployment/use-command-line-tools-depc4c80847a/web
- `pkgbuild(1)` Man Page: https://keith.github.io/xcode-man-pages/pkgbuild.1.html (and local `/usr/share/man/man1/pkgbuild.1`)
- Xcode Support & SDK Compatibility Matrix: https://developer.apple.com/support/xcode/
- Safari Release Notes: https://developer.apple.com/documentation/safari-release-notes
- Apple `container` CLI Repository & Releases: https://github.com/apple/container, https://github.com/apple/container/releases, https://github.com/apple/container/blob/main/Package.swift
- Apple `containerization` Framework Tags: https://github.com/apple/containerization/tags

### Sparkle 2 Documentation & Source Code
- Sparkle Basic Setup: https://sparkle-project.org/documentation/
- Sparkle Publishing an Update (`#internal-build-numbers`, `#channels`): https://sparkle-project.org/documentation/publishing/
- Sparkle Customization: https://sparkle-project.org/documentation/customization/
- `SUStandardVersionComparator.m`: https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SUStandardVersionComparator.m
- `SUVersionComparisonTest.m`: https://github.com/sparkle-project/Sparkle/blob/2.x/Tests/SUVersionComparisonTest.m
- `SUHost.m`: https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SUHost.m
- `SUAppcastItem.m`: https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SUAppcastItem.m
- `SUAppcastDriver.m`: https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SUAppcastDriver.m
- `SPUStandardVersionDisplay.m`: https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SPUStandardVersionDisplay.m

### Jamf Pro Documentation
- Jamf Pro Inventory / Applications Category: https://learn.jamf.com/r/en-US/jamf-pro-documentation-11.17.0/Applications_Category?contentId=O8Mb~DCRBDjYh5Lusmsiaw
- Jamf Pro Title Editor / Patch Definitions: https://learn.jamf.com/r/en-US/title-editor/Patch_Definitions?contentId=G86W~KJvl6vjTmgJpsmtDw
- Jamf Pro Creating a Patch Policy: https://learn.jamf.com/r/en-US/jamf-pro-documentation-11.30.0/Creating_a_Patch_Policy?contentId=sKlT0cEguK_G_u9gI3lH9Q
- Jamf Pro 11.23 New Smart Group Criteria (`Application Bundle Short Version` / `Application Bundle Version`): https://grahamrpugh.com/2025/12/02/new-smart-group-criteria.html

### Versioning Specifications
- Semantic Versioning 2.0.0: https://semver.org/
- Calendar Versioning (CalVer): https://calver.org/

### Container Desktops, Engines & GUIs
- Docker Desktop Release Notes: https://docs.docker.com/desktop/release-notes/
- Docker Desktop 2.x Archive (Dec 2018 transition to `2.0.0.0`): https://docs.docker.com/desktop/previous-versions/2.x-mac/
- Docker Engine 17.03 Release Notes (CalVer transition): https://docs.docker.com/engine/release-notes/17.03/
- Docker Engine 23.0 Release Notes (Return from CalVer to SemVer): https://docs.docker.com/engine/release-notes/23.0/
- Docker Engine 27 & 28 Release Notes: https://docs.docker.com/engine/release-notes/27/, https://docs.docker.com/engine/release-notes/28/
- Docker Prior Engine Release Notes (`1.12`–`1.13`): https://docs.docker.com/engine/release-notes/prior-releases/
- Docker Compose Release Notes: https://docs.docker.com/compose/releases/release-notes/, https://github.com/docker/compose/releases
- Docker Build / Buildx Release Notes: https://docs.docker.com/build/release-notes/, https://github.com/docker/buildx/releases
- `docker version` CLI Reference: https://docs.docker.com/reference/cli/docker/version/
- Rancher Desktop Releases & Docs: https://github.com/rancher-sandbox/rancher-desktop/releases, https://docs.rancherdesktop.io/ui/preferences/kubernetes/, https://docs.rancherdesktop.io/how-to-guides/upgrade-kubernetes/
- Podman Desktop Releases & Docs: https://github.com/podman-desktop/podman-desktop/releases, https://podman-desktop.io/docs/intro, https://podman-desktop.io/docs/installation
- Podman Engine Releases: https://github.com/containers/podman/releases
- OrbStack Release Notes: https://docs.orbstack.dev/release-notes
- Colima Releases & FAQ: https://github.com/abiosoft/colima/releases, https://github.com/abiosoft/colima/blob/main/docs/FAQ.md
- Portainer Releases & Compatibility Matrix: https://github.com/portainer/portainer/releases, https://docs.portainer.io/start/requirements-and-prerequisites
- Lazydocker Releases & Issue #580: https://github.com/jesseduffield/lazydocker/releases, https://github.com/jesseduffield/lazydocker/issues/580
- Orchard (`andrew-waters/orchard`): https://github.com/andrew-waters/orchard, https://github.com/andrew-waters/orchard/releases, https://github.com/andrew-waters/orchard/blob/main/CHANGELOG.md
- ContainerManager (`duminga/ContainerManager`): https://github.com/duminga/ContainerManager, https://github.com/duminga/ContainerManager/releases
- AppleContainerDesktop & Community Apple Container GUIs: https://github.com/0Itsuki0/AppleContainerDesktop/releases, https://github.com/ducheharsh/apple-container-desktop/releases, https://github.com/FeSens/container-gui/releases

### Packaging, Linux Distros, Kubernetes & Virtualization
- Homebrew Formula Cookbook (`revision`, `version_scheme`): https://docs.brew.sh/Formula-Cookbook#formulae-revisions, https://docs.brew.sh/Formula-Cookbook#version-scheme-changes
- Homebrew Versions & Bottles: https://docs.brew.sh/Versions, https://docs.brew.sh/Bottles
- Homebrew Cask Cookbook (`version` stanza): https://docs.brew.sh/Cask-Cookbook#stanza-version
- Debian Policy Manual §5.6.12 (`Version`): https://www.debian.org/doc/debian-policy/ch-controlfields.html#s-f-version
- Debian `deb-version(7)` & `dpkg(1)` Man Pages: https://manpages.debian.org/bookworm/dpkg-dev/deb-version.7.en.html, https://manpages.debian.org/bookworm/dpkg/dpkg.1.en.html
- Ubuntu Packaging Guide & Version Strings: https://documentation.ubuntu.com/ubuntu-packaging-guide/, https://wiki.ubuntu.com/SecurityTeam/BuildSystem#Version_Strings
- K3s Upgrades, Repo, Channel Server & Upgrade Controller: https://docs.k3s.io/upgrades, https://github.com/k3s-io/k3s, https://github.com/rancher/channelserver, https://github.com/rancher/system-upgrade-controller
- RKE2 Upgrades & Repo: https://docs.rke2.io/upgrade/basic_upgrade, https://github.com/rancher/rke2
- Google GKE Versioning and Release Channels: https://cloud.google.com/kubernetes-engine/docs/concepts/versioning-and-upgrades, https://cloud.google.com/kubernetes-engine/docs/concepts/release-channels
- AWS EKS Platform Versions & Optimized AMIs: https://docs.aws.amazon.com/eks/latest/userguide/platform-versions.html, https://docs.aws.amazon.com/eks/latest/userguide/eks-optimized-ami.html, https://docs.aws.amazon.com/eks/latest/userguide/retrieve-ami-id.html
- Azure AKS Supported Versions & Node Images: https://learn.microsoft.com/en-us/azure/aks/supported-kubernetes-versions, https://learn.microsoft.com/en-us/azure/aks/node-image-upgrade
- Proxmox VE Admin Guide, Roadmap & Kernel Wiki: https://pve.proxmox.com/pve-docs/pve-admin-guide.html, https://pve.proxmox.com/wiki/Roadmap, https://pve.proxmox.com/wiki/Proxmox_VE_Kernel

### Electron, IDEs, Terraform, Wine & Git GUIs
- Electron Versioning, Cadence & Timelines: https://www.electronjs.org/docs/latest/tutorial/electron-versioning, https://www.electronjs.org/blog/8-week-cadence, https://www.electronjs.org/docs/latest/tutorial/electron-timelines, https://www.electronjs.org/docs/latest/api/process#processversions
- VS Code Updates, Extension Manifest & Pre-release Extensions: https://code.visualstudio.com/updates, https://code.visualstudio.com/api/references/extension-manifest, https://code.visualstudio.com/api/working-with-extensions/publishing-extension#prerelease-extensions
- Signal Desktop Releases: https://github.com/signalapp/Signal-Desktop/releases
- Obsidian Changelog: https://obsidian.md/changelog/
- JetBrains Plugin Configuration, Build Ranges, Compatibility & SemVer: https://plugins.jetbrains.com/docs/intellij/plugin-configuration-file.html, https://plugins.jetbrains.com/docs/intellij/build-number-ranges.html, https://plugins.jetbrains.com/docs/intellij/plugin-compatibility.html, https://plugins.jetbrains.com/docs/marketplace/semver.html
- HashiCorp Terraform 0.10 Provider Split & Version Constraints: https://www.hashicorp.com/blog/upcoming-provider-changes-in-terraform-0-10, https://developer.hashicorp.com/terraform/language/block/terraform, https://developer.hashicorp.com/terraform/language/expressions/version-constraints, https://developer.hashicorp.com/terraform/language/providers/requirements, https://developer.hashicorp.com/terraform/plugin/terraform-plugin-protocol
- CodeWeavers CrossOver Changelog & Release Blog: https://www.codeweavers.com/crossover/changelog, https://www.codeweavers.com/blog/mjohnson/2024/2/15/crossover-24-has-landed
- Valve Proton Repo, Releases & Changelog: https://github.com/ValveSoftware/Proton, https://github.com/ValveSoftware/Proton/releases, https://github.com/ValveSoftware/Proton/wiki/Changelog
- Sourcetree, Tower, Fork, GitHub Desktop (`dugite`), and GitKraken: https://www.sourcetreeapp.com/download-archives, https://support.atlassian.com/sourcetree/, https://www.git-tower.com/release-notes, https://git-fork.com/release-notes, https://github.com/desktop/desktop/releases, https://github.com/desktop/dugite/releases, https://help.gitkraken.com/gitkraken-desktop/current-version/
