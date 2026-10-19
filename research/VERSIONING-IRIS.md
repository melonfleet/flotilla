**Flotilla’s scheme is understandable, but I recommend changing it before 1.5 final.** It works as a label for a certified build against a particular runtime. It is a poor long-term product version for an application with its own features, compatibility promises and roadmap.

Use independent Flotilla versions, retain the separate integer build number, and make runtime compatibility explicit. My recommended release sequence is:

**`1.5.0-beta.5` → `1.5.0-rc.1` → `1.5.0`**

For these releases, the tested and recommended `container` version remains **`1.5.0`**. Subsequent Flotilla numbers belong to Flotilla.

I inspected the mirror at commit [`e874bd2`](https://github.com/melonfleet/flotilla/tree/e874bd22c8b8ba030200e757e0db3f40c603e09b), including the September decision, October amendment, release scripts and both update paths. No files were written or code changed. The conclusions below distinguish documented behavior, source inspection and my judgment; I did not perform installations or test a live Jamf deployment.

**The implementation already separates product labels from update ordering.**

The September decision adopted `<container version>.<Flotilla revision>` to express certification while allowing Flotilla releases between Apple releases. The October 5 amendment changed the pending beta’s runtime prefix from `1.4.1` to `1.5.0`. That is internally coherent. However, the update architecture subsequently changed. [Versioning decision](https://github.com/melonfleet/flotilla/blob/e874bd2/DECISIONS.md#L508)

| Surface | What the inspected code actually uses |
|---|---|
| Public label | `make-app.sh` stamps the release label into `CFBundleShortVersionString`. Development builds can append `+<commits-since-tag>`. [Source](https://github.com/melonfleet/flotilla/blob/e874bd2/Scripts/make-app.sh#L101) |
| App build | `CFBundleVersion` is `git rev-list --count HEAD`. [Source](https://github.com/melonfleet/flotilla/blob/e874bd2/Scripts/make-app.sh#L149) |
| Sparkle | `publish-release.sh` reads the app’s **build number** into `sparkle:version`. The public label goes into `sparkle:shortVersionString`. `AppUpdater` selects channels without installing a custom version comparator. [Publisher](https://github.com/melonfleet/flotilla/blob/e874bd2/Scripts/publish-release.sh), [updater](https://github.com/melonfleet/flotilla/blob/e874bd2/Sources/Flotilla/AppUpdater.swift) |
| Installer package | `make-pkg.sh` passes the **commit count** to `pkgbuild --version`; the public label appears in filenames and installer presentation. [Source](https://github.com/melonfleet/flotilla/blob/e874bd2/Scripts/make-pkg.sh) |
| Fleet update selection | `FleetUpdate` extracts the integer in parentheses from the reported app version and compares that integer. [Source](https://github.com/melonfleet/flotilla/blob/e874bd2/Sources/FlotillaCore/Fleet/FleetUpdate.swift) |
| Host acceptance | `SelfUpdate` reads the incoming signed bundle’s `CFBundleVersion` as an `Int` and rejects an equal or lower build. The privileged helper independently applies the same rule. [App check](https://github.com/melonfleet/flotilla/blob/e874bd2/Sources/Flotilla/SelfUpdate.swift), [helper check](https://github.com/melonfleet/flotilla/blob/e874bd2/Sources/FlotillaHelper/main.swift#L234) |
| Wire compatibility | A separate protocol range, currently `1...13`, is negotiated. App-update uploads require wire version **6**, independently of the product version. [Protocol](https://github.com/melonfleet/flotilla/blob/e874bd2/Sources/FlotillaCore/Wire/WireFrame.swift) |
| Runtime selection | `ContainerRuntime.expectedVersion` independently specifies `"1.5.0"`. Runtime setup compares the installed runtime with this value; it does not derive it from the app label. [Source](https://github.com/melonfleet/flotilla/blob/e874bd2/Sources/FlotillaCore/ContainerPackage.swift) |

`SemanticVersion` does implement the intended four-component ordering: missing components become zero, prereleases precede their corresponding final release, and `+metadata` is ignored. Thus `1.5.0.0` and `1.5.0` compare equal. Its formatted description also removes a zero fourth component. This is a custom extension of SemVer, explicitly acknowledged in its comments. [Implementation](https://github.com/melonfleet/flotilla/blob/e874bd2/Sources/FlotillaCore/SemanticVersion.swift)

There is also a different `SoftwareVersion` parser for version-skew reporting. It uses the first three numeric components and an optional parenthesized build number; it does not preserve the fourth revision or prerelease distinction. Consequently, the four-part label does not have one universal interpretation even inside Flotilla. [Version-skew implementation](https://github.com/melonfleet/flotilla/blob/e874bd2/Sources/FlotillaCore/Fleet/VersionSkew.swift)

Three findings change the assessment of the original decision:

- **The fourth component is no longer necessary for application update ordering.** Q40 retired Flotilla’s own release checker in favor of Sparkle. Sparkle and fleet updates now order integer builds. The original objections to `-flotilla.N` and `+flotilla.N` were correct for that custom comparator, but no longer establish that a fourth component is necessary. [Q40](https://github.com/melonfleet/flotilla/blob/e874bd2/DECISIONS.md#L1933)
- **The runtime is separately installed and can differ from the label.** The README says Flotilla does not bundle it; setup deliberately leaves a newer runtime alone. The number therefore identifies the tested runtime, not necessarily the installed runtime. [README](https://github.com/melonfleet/flotilla/blob/e874bd2/README.md#L49), [runtime setup](https://github.com/melonfleet/flotilla/blob/e874bd2/Sources/FlotillaCore/ContainerPackage.swift#L113)
- **The upstream compatibility premise has changed.** Apple’s README at the actual `1.5.0` tag says its releases use product versions, not semantic versions; CLI compatibility is generally preserved within a major release, with possible exceptions and no such guarantee for experimental features. That is broader than the September decision’s “patch-series only” premise, although it still requires testing. [Apple’s version-specific statement](https://github.com/apple/container/blob/1.5.0/README.md#project-status)

**The closest prior art favors an independent application version.**

The examples below are concrete historical releases, not a claim that each is the latest release. Vendors often document the numbers and compatibility mechanisms without explaining their original naming decision. Unless a rationale is expressly documented, the “lesson” column is my inference.

| Product | Actual scheme and dependency relationship | Lesson for Flotilla |
|---|---|---|
| **Docker Desktop** | Desktop **4.34.0** shipped Docker Engine **27.2.0**, Compose **2.29.2**, containerd **1.7.20** and Buildx **0.16.2**. These versions are listed separately. [Release notes](https://docs.docker.com/desktop/release-notes/#4340) | The desktop product has its own release identity despite closely integrating several independently versioned components. |
| **Rancher Desktop** | Desktop **1.16.0** separately listed Docker CLI **27.2.1**, Compose **2.29.5** and nerdctl **1.7.7**. Users can select containerd or dockerd/Moby as the runtime. [Release](https://github.com/rancher-sandbox/rancher-desktop/releases/tag/v1.16.0), [engine selection](https://docs.rancherdesktop.io/ui/preferences/container-engine/general/) | An application can manage alternative engines without incorporating either engine’s number into its own version. |
| **Podman Desktop** | Desktop **1.9** included Podman **4.9.4**, while offering **5.0.1** for new users and experimentally for existing users. The vendor explicitly explains that Podman 5’s machine changes require a migration. [Release announcement](https://podman-desktop.io/blog/podman-desktop-release-1.9) | Especially relevant: one desktop release can support different runtime generations, with compatibility and migration explained separately. |
| **OrbStack** | OrbStack **1.7.1** listed Docker **27.1.2**, Compose **2.29.2** and Linux **6.10.7** separately. [Release notes](https://docs.orbstack.dev/release-notes#v1-7-1-september-2-2024) | Even a tightly integrated Mac container application does not need an engine-derived product number. |
| **Colima** | Colima **0.7.6** introduced `colima update`, explicitly allowing runtime updates without upgrading Colima or waiting for its next release. Its FAQ describes the runtime bundled with releases separately. [Release](https://github.com/abiosoft/colima/releases/tag/v0.7.6), [FAQ](https://github.com/abiosoft/colima/blob/main/docs/FAQ.md) | This is direct evidence for separating a CLI-driving product’s cadence from the runtime’s cadence. |
| **Tower** | Tower **14.4**, build **495**, updated its bundled Git to **2.51**. Tower’s support form separately requests Tower version/build and Git version. [Release history](https://www.git-tower.com/updates/tower3-mac/stable/releases), [support form](https://www.git-tower.com/support/contact) | Very close native-GUI precedent: product version, build number and underlying CLI version are separate support facts. |
| **Sourcetree** | Sourcetree **4.2.8** is an application release number. Users can choose embedded or system Git, and Windows users can update embedded Git separately. [Release notes](https://product-downloads.atlassian.com/software/sourcetree/ReleaseNotes/Sourcetree_4.2.8.html), [Git selection](https://support.atlassian.com/sourcetree/kb/using-embedded-git-or-system-git-in-sourcetree/) | Particularly close to Flotilla’s separately installed CLI: the application number cannot reliably identify every user’s Git installation. |
| **Portainer** | Portainer **2.20.3** addressed incompatibilities with Docker **26**; the vendor separately announced fuller support in **2.21**. Its compatibility tables distinguish tested configurations from configurations that merely might work. [Compatibility incident](https://www.portainer.io/blog/portainer-and-docker-26), [validation matrix](https://docs.portainer.io/start/requirements-and-prerequisites) | Independent numbering does not eliminate compatibility work. A visible, maintained compatibility matrix does the work the borrowed number cannot. |

The strongest precedents for Flotilla are **Tower, Sourcetree, Podman Desktop, Colima and Portainer**. They combine independently evolving user-facing functionality with a dependency whose version and compatibility remain independently important.

**Tracking upstream is established practice when the version identifies a downstream distribution or package.**

| System | Exact convention and documented purpose | Relevance |
|---|---|---|
| **Homebrew formula revisions** | Homebrew adds a separate integer `revision`, defaulting to zero. A positive revision renders as `upstream_revision`, for example the illustrative `1.2.3_1`. It triggers a new package/rebuild without an upstream release, including dependency relinking and security fixes. `version_scheme` provides an ordering override when the upstream numbering scheme changes. [Revision policy](https://docs.brew.sh/Formula-Cookbook#formulae-revisions), [representation](https://docs.brew.sh/rubydoc/PkgVersion.html#to_str-instance_method), [version-scheme API](https://docs.brew.sh/rubydoc/Formula.html#version_scheme-class_method) | This identifies Homebrew’s packaging of the upstream program. It does not make a separate application adopt the version of one of its dependencies. |
| **Debian packages** | `[epoch:]upstream_version[-debian_revision]`. The revision normally restarts at `1` when upstream changes. Comparison considers epoch, upstream version, then Debian revision. Epochs handle numbering discontinuities and should be used sparingly. Debian uses `~` for versions that should precede a release. [Debian Policy](https://www.debian.org/doc/debian-policy/ch-controlfields.html#version) | A good precedent for a downstream build of the same software, with an explicitly defined package comparator. |
| **Ubuntu packages** | Ubuntu extends Debian’s packaging revision: the official example `2.6-1ubuntu1` means upstream **2.6**, Debian revision **1**, Ubuntu modification **1**. `-0ubuntu1` is used when there is no Debian package revision to inherit. Ubuntu also distinguishes no-change `buildN` rebuilds. [Packaging example](https://ubuntu.com/project/docs/how-ubuntu-is-made/concepts/debian-directory/), [version-string policy](https://ubuntu.com/project/docs/how-ubuntu-is-made/concepts/version-strings/) | Multiple packaging authorities get separate revision fields because they are producing variants of the upstream package. |
| **K3s** | **`v1.30.2+k3s1`**, followed by **`v1.30.2+k3s2`**, both distribute Kubernetes **1.30.2**. K3s explicitly says its numbering reflects upstream Kubernetes and the suffix allows additional K3s releases against the same upstream version. [Policy](https://github.com/k3s-io/k3s#release-cadence), [actual releases](https://docs.k3s.io/release-notes-old/v1.30.X) | Strong evidence that tracking is sensible when the product is a Kubernetes distribution. |
| **RKE2** | **`v1.30.2+rke2r1`** identifies an RKE2 release containing Kubernetes **1.30.2**; release tables separately enumerate containerd, etcd and other components. [Release table](https://docs.rke2.io/release-notes-old/v1.30.X) | Another distribution convention, not an example of a GUI borrowing an external engine’s product identity. |
| **Amazon EKS** | Kubernetes version and EKS platform version are separate fields. Platform versions use **`eks.N`**, independently for each Kubernetes minor series. AWS explains that these represent control-plane capabilities, configuration and fixes; for example, its table lists Kubernetes **1.34.9** under multiple platform revisions. [Platform-version policy](https://docs.aws.amazon.com/eks/latest/userguide/platform-versions.html) | EKS exposes two dimensions instead of requiring one number to carry both meanings. |
| **AKS** | The control plane follows Kubernetes **`MAJOR.MINOR.PATCH`**. Node images have separate identities, such as **`AKSUbuntu-2404-202601.27.0`**, and can be upgraded without changing Kubernetes version. [Component versioning](https://learn.microsoft.com/en-us/azure/aks/aks-component-versioning), [node-image upgrades](https://learn.microsoft.com/azure/aks/upgrade-node-image) | Another explicit separation between API/platform version and implementation/package revisions. |
| **GKE** | **`X.Y.Z-gke.N`**: upstream Kubernetes plus a GKE patch number. Google’s examples include **`1.35.6-gke.1638000`**. GKE can publish several patches for the same upstream Kubernetes patch. [Versioning policy](https://docs.cloud.google.com/kubernetes-engine/versioning#versioning_scheme) | A legitimate vendor distribution suffix, interpreted within GKE’s own release system. |

These conventions must not be mixed indiscriminately. In SemVer, `+k3s1` and `+k3s2` have **equal precedence**; a `-gke.N` suffix is syntactically a prerelease even when Google uses it for a production distribution. Debian’s `-revision` has different semantics again. Their practical success does not make those suffixes interchangeable ordering mechanisms. [SemVer specification](https://semver.org/)

My inference: **the Debian/Homebrew analogy supports Flotilla’s original scheme only partially**. Flotilla is shipping its own application, while Apple’s runtime remains a separate installation and upgrade operation. The revision is describing substantially more than repackaging Apple’s software.

**Other ecosystems reinforce the separation between product identity and dependency compatibility.**

| Ecosystem | Primary-source example | Implication |
|---|---|---|
| **Electron applications** | VS Code **1.92** adopted Electron **30**, containing Chromium **124.0.6367.243** and Node **20.14.0**. [VS Code release notes](https://code.visualstudio.com/updates/v1_92#_electron-30-update) | An application’s number describes its own release, while runtime upgrades are release-note facts. |
| **Electron itself** | Electron uses its own SemVer numbering. Its policy maps Chromium updates and Node major updates to Electron major increments without copying their numbers. [Electron versioning](https://www.electronjs.org/docs/latest/tutorial/electron-versioning) | Dependency changes can influence the significance of a product release without owning its numeric identity. |
| **VS Code extensions** | VSCodeVim **1.27.3** declares `engines.vscode: "^1.74.0"`. The platform defines separate extension `version` and compatible IDE `engines` fields. [Actual manifest](https://github.com/VSCodeVim/Vim/blob/v1.27.3/package.json), [manifest specification](https://code.visualstudio.com/api/references/extension-manifest) | Almost exactly the “own version plus requires…” alternative. Compatibility is machine-readable. |
| **JetBrains plugins** | A plugin has its own version and independently declares compatible IDE builds using `since-build` and optional upper-bound fields. [Plugin descriptor](https://plugins.jetbrains.com/docs/intellij/plugin-configuration-file.html), [build ranges](https://plugins.jetbrains.com/docs/intellij/build-number-ranges.html) | IDE compatibility is a separate axis, including when compatibility changes without a major plugin feature release. |
| **Terraform providers** | HashiCorp prescribes provider SemVer based on provider behavior. Terraform’s own version constraint and provider constraints are separate; its tutorial demonstrates Terraform `~> 1.1.9` and AWS provider `~> 5.52.0`. [Provider policy](https://developer.hashicorp.com/terraform/plugin/best-practices/versioning), [separate constraints](https://developer.hashicorp.com/terraform/tutorials/configuration-language/versions) | A wrapper/integration can define meaningful compatibility promises of its own. |
| **CrossOver / Wine** | CrossOver **24.0.0** incorporated Wine **9.0**, Wine Mono **8.1.0**, vkd3d **1.10** and MoltenVK **1.2.5**. [Official announcement](https://www.codeweavers.com/support/forums/announce?t=24%3Bmsg%3D299331) | A product built around another project can retain its own identity and document its upstream composition. |
| **Proxmox VE** | Proxmox VE **8.2** was based on Debian **12.5**, with QEMU **8.1**, Linux **6.8** and LXC **6.0**. [Vendor announcement](https://www.proxmox.com/en/about/company-details/press-releases/proxmox-virtual-environment-8-2) | Even an integrated virtualization distribution need not borrow the number of its OS or virtualization engine. |
| **Xcode / SDKs** | Xcode **16** included SDKs for iOS **18**, macOS **15**, watchOS **11** and visionOS **2**. [Apple release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-16-release-notes) | Apple itself treats the application/toolchain release and its supported platforms as separate identities. |
| **Safari / WebKit** | Apple presents browser capabilities as **Safari 18.0**, with the corresponding WebKit changes documented separately. Safari Technology Preview **200** explicitly identifies WebKit changes between **`280675@main` and `281143@main`**. [Safari/WebKit release](https://webkit.org/blog/15865/webkit-features-in-safari-18-0/), [preview provenance](https://webkit.org/blog/15779/release-notes-for-safari-technology-preview-200/) | Browser release identity, preview sequence and engine provenance need not share a number. |

This is not proof by popularity. It establishes that independent versions plus compatibility information are an ordinary, well-supported design for precisely this class of application.

**Apple’s documented version formats contradict the comments in `make-app.sh`.**

`CFBundleShortVersionString` is user-visible, but that does **not** make it unrestricted display text. Apple specifies **three period-separated integers**, containing only digits and periods. Both the fourth component and the `-beta.N`/`+N` suffixes fall outside that documented format. Apple also says this number should match the version entered in App Store Connect. [Bundle-key documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleshortversionstring), [App Store version definition](https://developer.apple.com/help/glossary/version-number/)

For `CFBundleVersion`, current documentation specifies **one to three numeric components**, permits omitted components, and says additional integers are ignored by the system. Mac builds must increase across product versions. A positive integer build number therefore fits the intended design well. [Build-key documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion), [distribution requirements](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution)

One historical wrinkle: Apple’s archived reference describes component digit limits and development suffixes that differ from its current documentation. Modern Xcode Cloud documentation explicitly gives integer examples including `420000`. I would not claim that the old four-digit first-component limit proves today’s integer scheme will fail at build 10,000. Use the current numeric contract and validate the actual distribution channel. [Archived reference](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html#//apple_ref/doc/uid/TP40009249-SW1), [Xcode Cloud build numbers](https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds)

The consequences differ by subsystem:

| Subsystem | Assessment of Flotilla’s current four-part short version |
|---|---|
| **App Store / TestFlight submission** | It does not meet the documented version format. Neither does a three-part version with `-beta.N` in that field. Keep prerelease presentation outside the short-version key. [Apple requirements](https://developer.apple.com/help/glossary/version-number/) |
| **Sparkle** | No present ordering problem: Flotilla supplies the integer build as the comparison version. The short string is presentation. [Sparkle item fields](https://sparkle-project.org/documentation/api-reference/Classes/SUAppcastItem.html) |
| **`installer` / `.pkg`** | Flotilla explicitly supplies a numeric package version, so the public label is not its package-ordering value. Package version checks and bundle replacement checks are separate concerns; a higher receipt version alone is not a universal proof of downgrade prevention. Apple’s shipped `pkgbuild(1)` manual describes both `--version` and `BundleIsVersionChecked`. [Flotilla packaging](https://github.com/melonfleet/flotilla/blob/e874bd2/Scripts/make-pkg.sh), [Apple-authored manual, online reproduction](https://keith.github.io/xcode-man-pages/pkgbuild.1.html) |
| **MDM inventory** | Apple exposes separate `ShortVersion` and `Version` strings. Inventory reporting is not itself a guarantee of a particular ordering algorithm. Declarative package management also has a manifest `bundle-version` used to detect updates. [Inventory schema](https://developer.apple.com/documentation/devicemanagement/installedapplicationlistresponse/installedapplicationlistitem), [package management](https://developer.apple.com/documentation/devicemanagement/installing-packages) |
| **Jamf** | Four components are not inherently unreportable: Jamf’s own documentation illustrates Chrome `88.0.4324.150`. But reporting a string does not establish reliable ordering of Flotilla’s suffixes. Since Jamf Pro **11.23**, computer inventory explicitly exposes both Application Bundle Version and Application Bundle Short Version. [Jamf’s Chrome example](https://resources.jamf.com/documents/white-papers/understanding-the-app-lifecycle-automate-update-deploy.pdf), [inventory change](https://learn.jamf.com/r/en-US/jamf-pro-release-notes-11.23.0/Inventory_Reporting) |
| **`softwareupdate`** | This is not Flotilla’s update mechanism. Apple’s system-update service distributes macOS and associated Apple updates; an arbitrary third-party app’s version label does not enroll it in that service. [Apple’s distinction](https://support.apple.com/guide/mac-help/get-macos-updates-and-apps-mh35618/mac), [Flotilla updater](https://github.com/melonfleet/flotilla/blob/e874bd2/Sources/Flotilla/AppUpdater.swift) |
| **LaunchServices** | Apple’s documented application-selection rules use `CFBundleVersion` when choosing among versions of the same application. Keeping that field increasing and numeric addresses the relevant ordering rule. This does not validate arbitrary contents of the short-version field. [LaunchServices rules](https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/LaunchServicesConcepts/LSCConcepts/LSCConcepts.html) |

I found **no basis for claiming that four components presently break all direct-distribution Mac applications, Jamf inventory or Flotilla’s Sparkle updates**. The accurate objection is narrower: Flotilla is relying on tolerance outside Apple’s documented short-version contract and gaining little in return.

**Sparkle supports the separation Flotilla already makes.**

Sparkle expressly documents an internal build such as `1248` paired with a human-facing version such as `1.5.1`. Its default comparator documentation recommends numeric forms `x`, `x.y` or `x.y.z`. [Publishing guidance](https://sparkle-project.org/documentation/publishing/#internal-build-numbers), [comparator API](https://sparkle-project.org/documentation/api-reference/Classes/SUStandardVersionComparator.html)

It is also **not Flotilla’s SemVer comparator**. In the Sparkle **2.10.0** source corresponding to this checkout’s resolved dependency, tokenization stops at a hyphen. Thus, if incorrectly supplied as comparison versions, `1.5.0-beta.4` and `1.5.0-beta.5` would lose their distinguishing suffixes. The implementation also balances missing trailing numeric components with zeros. This is source-derived behavior, not a native execution test. [Pinned comparator source](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Sparkle/SUStandardVersionComparator.m), [Flotilla dependency resolution](https://github.com/melonfleet/flotilla/blob/e874bd2/Package.resolved)

Continue using integer builds for Sparkle. Do not replace them with either the current four-part label or a SemVer prerelease label.

**The roadmap tension is substantive.**

The roadmap’s “Version 2.0” already groups Flotilla work: fleet trust, service tunnels, management features and other product capabilities. The migration research separately discusses a “2.0 high-availability idea,” while other research refers to Greta’s 1.5 scope. Those are Flotilla milestones, not descriptions of Apple’s runtime. [Roadmap](https://github.com/melonfleet/flotilla/blob/e874bd2/PLAN.md#L797), [HA research](https://github.com/melonfleet/flotilla/blob/e874bd2/research/MIGRATION-HA.md), [Greta-related scope](https://github.com/melonfleet/flotilla/blob/e874bd2/research/MACOS-INTEGRATIONS.md)

My assessment is that the current scheme creates three avoidable misunderstandings:

1. **Flotilla makes a major change while Apple stays on 1.5.0.** The release must become something like `1.5.0.27`. That can identify the build, but it gives users no useful signal that Flotilla’s configuration, workflows or compatibility changed substantially.
2. **Apple releases 2.0 while Flotilla changes little.** Flotilla becomes `2.0.0.0`, consuming the product’s advertised 2.0 milestone regardless of whether its promised features exist.
3. **Flotilla supports several runtime versions.** A single borrowed version can identify one tested baseline but cannot express the supported set, minimum requirement, installed version and feature-specific exceptions.

These are predictions about interpretation, not results of a user study. Nevertheless, the conflict is already visible in the repository’s vocabulary.

A version number can identify a release and participate in an ordering policy. A semantic version additionally communicates compatibility against a declared public interface. It cannot, by itself, prove testing or describe every dependency relationship. [SemVer’s declared-interface requirement](https://semver.org/)

For Flotilla, I would explicitly distinguish:

| Fact | Appropriate representation |
|---|---|
| Which Flotilla release is this? | Product version, such as `1.5.0` |
| Which exact distributable is newer? | Integer build number |
| Which runtime versions were tested and supported? | Compatibility metadata and release notes |
| Can these two peers communicate and perform this operation? | Negotiated wire version and feature requirements |

Flotilla already implements most of those distinctions. The public label should reflect them.

**The alternatives are all mechanically possible, but they communicate different things.**

The examples below are proposed labels. In every option, I would retain an increasing integer build for Sparkle, package versions and fleet updates.

| Alternative | Advantages for Flotilla | Disadvantages and migration implications |
|---|---|---|
| **Independent `MAJOR.MINOR.PATCH` plus runtime requirements** | Product milestones belong to Flotilla; ordinary three-part final versions fit Apple’s documented short-version format; runtime support can span multiple releases. | Requires maintaining explicit compatibility information. “Requires `container ≥1.5.0`” alone is insufficient: it states a floor, not evidence that all future versions work. Migrate to `1.5.0-beta.5`, then `1.5.0-rc.1`, then `1.5.0`. |
| **Calendar versioning** | Makes release freshness apparent and avoids borrowing Apple’s product significance. This is sensible for frequently updated data. [CalVer conventions](https://calver.org/) | `YYYY.MM.DD.N` still has four components, so copying the library’s format does not solve the bundle-format issue. Use, for example, public label `2026.10.19.0` but a three-part bundle version plus separate build, or choose a three-part calendar convention. Product “2.0” milestones would need renaming. Moving back to small product numbers later complicates external inventory ordering. |
| **Independent SemVer plus metadata** | A label such as `1.5.0-beta.5+container.1.5.0` records provenance without assigning Apple ownership of Flotilla’s major/minor numbers. | Long for ordinary UI; metadata does not express a compatibility range. Metadata-only differences have equal SemVer precedence, so meaningful releases still need their own version/build policy. Keep `+…` outside `CFBundleShortVersionString`. [Metadata rule](https://semver.org/#spec-item-10) |
| **Current tracking scheme** | Immediately exposes one tested runtime version to people who know the convention. Custom ordering is straightforward. | Continues the roadmap conflict; does not identify the installed runtime or supported range; retains nonstandard public syntax. Next label would be `1.5.0.0-beta.5`. To comply with Apple’s field format, the full label would still need a separate display field. |
| **Independent product version plus a prominent runtime badge and compatibility record** | Combines normal product numbering with the visibility the original decision wanted. About can say `Flotilla 1.5.0` and `Tested with container 1.5.0` together. | Slightly more metadata and UI work. This is my preferred implementation of independent numbering, using the same migration sequence as the first option. |

The suggestions library is a useful counterexample to “one scheme everywhere.” Its own parser explicitly requires four numeric components and orders them numerically; the built-in library is `2026.10.12.0`. That format lives in an independently versioned data document, not Apple’s bundle-version fields. It can remain unchanged. [Library implementation](https://github.com/melonfleet/flotilla/blob/e874bd2/Sources/FlotillaCore/SuggestionLibrary.swift)

Two other hybrids offer less value:

- **Upstream major/minor plus Flotilla patch**, such as `1.5.7`, fits three components but still gives Apple control of “2.0” and no longer identifies the exact tested upstream patch.
- **`container-version+flotilla.N`** is now mechanically feasible because builds order updates. It nevertheless preserves the product-identity problem and loses revision ordering in generic SemVer consumers.

For every alternative, compatibility should be communicated through the following surfaces. Tracking or metadata suffixes may supplement these fields; they cannot replace them.

| Surface | Recommended behavior |
|---|---|
| **About and diagnostics** | Show full Flotilla release label, build number, tested/recommended runtime, and the actual installed runtime. For fleet diagnostics, report the runtime per host. |
| **Release notes** | State requirements and tested versions near the top. Describe changes to supported versions explicitly. Separate a runtime-certification change from new Flotilla functionality. |
| **Application update check** | Order by build and channel. Sparkle’s OS requirement is not a `container` requirement. Runtime compatibility needs Flotilla-owned checks or metadata; a new product label alone supplies neither. [Sparkle’s available fields](https://sparkle-project.org/documentation/api-reference/Classes/SUAppcastItem.html) |
| **Host-update and wire checks** | Keep build-number anti-downgrade checks separate from protocol negotiation. Check runtime requirements against the destination host’s runtime facts; do not infer wire compatibility from matching product majors. |
| **Jamf / MDM** | Inventory the product short version and build separately. Use build-based criteria to distinguish betas, candidates and final builds that share a numeric short version. Inventory the runtime separately as well. [Jamf inventory fields](https://learn.jamf.com/r/en-US/jamf-pro-release-notes-11.23.0/Inventory_Reporting) |

The ordering result for each alternative is therefore:

| Scheme | Sparkle | Installer/package | Host updates | Jamf |
|---|---|---|---|---|
| Independent versions | Increasing build | Increasing numeric package/build values | Increasing integer build; separate wire checks | Three-part product version; build distinguishes prereleases |
| Calendar versions | Same | Same | Same | Calendar short version plus build; do not assume four-part suffix ordering |
| SemVer plus metadata | Same; metadata is display/provenance | Same | Same | Numeric core plus build; collect metadata separately if needed |
| Current tracking | Same | Same | Same | Raw label can be reported, but use build criteria rather than assuming its custom semantics |
| Independent version plus runtime badge | Same | Same | Same | Product build and runtime compatibility are separately queryable |

These are recommendations for operating each scheme reliably. They are not a claim that every existing Jamf policy automatically chooses the correct field.

**There is a straightforward migration for existing beta users.**

The mirror’s `gh-pages` appcast records:

- Beta 2: build **347**
- Beta 3: build **392**
- Beta 4: build **422**

The checkout’s commit count is **564**. I inspected the local appcast snapshot; the live URL was not retrievable through the research browser. [Appcast source](https://github.com/melonfleet/flotilla/blob/gh-pages/appcast.xml)

Consequently, renaming the next beta does not require resetting builds, changing application identity or publishing an intermediate legacy-format release.

I recommend this exact representation:

| Field | Next beta | First release candidate | Final |
|---|---|---|---|
| Git tag | `v1.5.0-beta.5` | `v1.5.0-rc.1` | `v1.5.0` |
| Public display label | `1.5.0-beta.5` | `1.5.0-rc.1` | `1.5.0` |
| `CFBundleShortVersionString` | `1.5.0` | `1.5.0` | `1.5.0` |
| `CFBundleVersion` | `B₁` | `B₂ > B₁` | `B₃ > B₂` |
| Package version | `B₁` | `B₂` | `B₃` |
| `sparkle:version` | `B₁` | `B₂` | `B₃` |
| `sparkle:shortVersionString` | `1.5.0-beta.5` | `1.5.0-rc.1` | `1.5.0` |
| Sparkle channel | `beta` | `beta` | Default: omit channel |
| Tested/recommended runtime | `1.5.0` | `1.5.0` | `1.5.0` |

Here `B₁` must exceed **every build that recipients may already have**, including fleet development builds—not merely public beta 4. If 564 is the highest distributed build and the next release commit has count 565, then **565, 566, 567** illustrate a valid sequence. Actual release commits may produce larger numbers.

Sparkle’s default channel is always included alongside explicitly allowed channels, so prerelease subscribers can receive the final default-channel release. Users configured for stable updates would skip the next beta and receive the higher-build final. [Sparkle channel semantics](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html)

The implementation plan should be:

1. **Amend the versioning decision before the next beta.** Preserve the obligation to review and test every Apple release. End the obligation to copy Apple’s version into Flotilla’s product number. Certification-only releases can be named as Flotilla maintenance releases and explained accordingly.

2. **Separate the display label from Apple’s short-version field.** Introduce an application-owned display value, such as `FLDisplayVersion`, for `1.5.0-beta.5`. Use it in About, window chrome, diagnostics and the human-readable portion of host identity. Keep the parenthesized integer build intact. Sparkle offers a version-display customization interface if needed for consistent local presentation. [Display protocol](https://sparkle-project.org/documentation/api-reference/Protocols/SUVersionDisplay.html)

3. **Make compatibility explicit without overstating it.** For the next release, record minimum, tested and recommended runtime information separately. The evidenced tested version is **1.5.0**. Treat later untested releases as unverified rather than assuming that a numerically newer version is supported. Keep Apple’s existing no-downgrade behavior. The necessary runtime constant already exists independently of the app label. [Runtime configuration](https://github.com/melonfleet/flotilla/blob/e874bd2/Sources/FlotillaCore/ContainerPackage.swift)

4. **Keep existing application, package and update identities.** Preserve the bundle identifier, package identifier, feed URL, signing identities and Sparkle verification key. Publish new artifacts under new tags; leave existing tags and artifacts intact. No wire-version change is needed merely to rename the product version.

5. **Keep integer build ordering and strengthen its allocation rules.** A commit count increases along a full-history descendant chain. It is not a global release counter: parallel branches can collide, shallow histories count differently, and rebuilding or relabeling the same commit does not increase it. This follows from Git’s definition of reachable-commit counting. [Git documentation](https://git-scm.com/docs/git-rev-list)

   For the immediate transition, a checked full-history release sequence is sufficient. Before shipping parallel maintenance branches or independently rebuilt artifacts, use a shared monotonic build allocator for all distributed builds, including fleet builds. Preserve the integer format because existing hosts parse it as an `Int`.

6. **Update deployment criteria to use the installed app’s build.** In current Jamf, use Application Bundle Version; in older deployments, an integer extension attribute can expose the same value. Do not rely solely on package receipts: Sparkle and fleet replacement can update the app without installing another package, leaving the receipt behind. That follows directly from Flotilla’s separate ZIP/app-replacement paths. [Fleet replacement](https://github.com/melonfleet/flotilla/blob/e874bd2/Sources/Flotilla/SelfUpdate.swift), [package path](https://github.com/melonfleet/flotilla/blob/e874bd2/Scripts/make-pkg.sh)

7. **Validate the transition using the shipped beta.** Before publishing, exercise beta 4/build 422 → new beta → final through Sparkle, and through both writable-app and root-owned fleet installations. Check the generated package and Jamf inventory, including beta-to-final differentiation. Confirm that older builds remain rejected where anti-downgrade protection is intended. These are release-validation tasks; they were not performed during this read-only research.

Even the old custom label comparator supports the proposed sequence:

```text
1.5.0.0-beta.4
    < 1.5.0-beta.5
    < 1.5.0-rc.1
    < 1.5.0
```

That follows because the missing fourth component becomes zero. It is useful reassurance, although **the actual update guarantee remains the increasing build number**. [Comparator](https://github.com/melonfleet/flotilla/blob/e874bd2/Sources/FlotillaCore/SemanticVersion.swift)

My final judgment is that the present scheme was a reasonable early attempt to make certification visible. It remains suitable if Flotilla deliberately defines itself as a versioned distribution of a particular Apple runtime. The current application, separate-runtime installation model and independent roadmap make that an increasingly inaccurate description.

Make the change **before 1.5 final**, retain **1.5.0** as Flotilla’s first independent release number, and make the next beta **`1.5.0-beta.5`**. Then a future **Flotilla 2.0** can mean the Flotilla milestone the roadmap actually promises.
