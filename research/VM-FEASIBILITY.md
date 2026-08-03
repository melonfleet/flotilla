# General-purpose VM host — feasibility facts

Scope: **(b) a general-purpose VM host** — guest operating systems installed from ISOs,
cloud images or restore images, with arbitrary disk images and optionally a display. On
macOS that means Apple's **Virtualization.framework**, or a second engine such as QEMU.
This document is **not** about `container machine`, the Apple CLI's own headless Linux
micro-VMs that host containers; that is [MACHINES-SPEC.md](MACHINES-SPEC.md).

This document establishes facts only. It makes **no product recommendation** — that is
the owner's and the core owner's call. The security posture of the same proposal is reviewed separately
in [VM-SECURITY-REVIEW.md](VM-SECURITY-REVIEW.md), and the two agree on the one decisive
point (bridged networking needs an entitlement Apple does not hand out on request).

Every claim below carries a URL. Where I could not confirm something from a primary
source, it is labelled **unverified** rather than inferred. Two fetch caveats: Apple's
documentation site renders via JavaScript, so all Apple citations were read through the
`developer.apple.com/tutorials/data/…json` document endpoints that back the HTML pages
(the human-readable URL is given); and `docs.getutm.app` and `mac.getutm.app` return HTTP
403 to automated fetches, so UTM's own wording is quoted from the search index and marked
where that matters.

## The brief's established facts — checked

Both hold.

| Claim in the brief | Verdict | Evidence |
|---|---|---|
| `VZLinuxBootLoader`, `VZEFIBootLoader`, `VZMacOSBootLoader`, `VZMacOSInstaller`, `VZMacOSRestoreImage` all ship | **Confirmed.** `VZMacOSBootLoader` is macOS 12+ and must be paired with `VZMacPlatformConfiguration`; `VZEFIBootLoader` is macOS 13+ | [VZMacOSBootLoader](https://developer.apple.com/documentation/virtualization/vzmacosbootloader), [VZEFIBootLoader](https://developer.apple.com/documentation/virtualization/vzefibootloader), [VZMacOSRestoreImage](https://developer.apple.com/documentation/virtualization/vzmacosrestoreimage) |
| There is **no Windows class of any kind** | **Confirmed** for the public API. Apple's own framework summary scopes the whole thing to "macOS or Linux-based operating systems" | [Virtualization framework overview](https://developer.apple.com/documentation/virtualization) |
| `VZGraphicsDevice` / `VZGraphicsDisplay` exist, so GUI guests are possible | **Confirmed.** `VZGraphicsDisplay` is macOS 14+, reachable via `VZGraphicsDevice.displays`, subclassed as `VZMacGraphicsDisplay` and `VZVirtioGraphicsScanout`, and resizable at runtime. Linux GUI output specifically uses `VZVirtioGraphicsDeviceConfiguration`, macOS 13+ | [VZGraphicsDisplay](https://developer.apple.com/documentation/virtualization/vzgraphicsdisplay), [VZVirtioGraphicsDeviceConfiguration](https://developer.apple.com/documentation/virtualization/vzvirtiographicsdeviceconfiguration) |

One addition the brief did not ask for but that decides question 1: **there is no TPM or
vTPM class either.** I found none in the framework's documented symbol set and no
third-party binding exposes one. This is the concrete blocker for Windows 11, which
requires TPM 2.0 — Lima had to spawn an external `swtpm` process alongside QEMU to get
Windows 11 to install at all
([Lima v2.2 release notes](https://www.cncf.io/blog/2026/07/28/lima-v2-2-windows-guests-and-tpm-2-0-emulation/)).
**Unverified:** I did not dump the macOS 26.5 SDK headers to prove absence exhaustively;
this is absence from the public documentation plus absence from every binding I looked at.

## Summary

| # | Question | Finding | Confidence |
|---|---|---|---|
| 1 | Guest OS support | Virtualization.framework: **macOS and Linux only**, documented. No Windows path, no TPM, no cross-architecture. Windows on Apple silicon requires a *different* engine — QEMU/HVF, Parallels, VMware Fusion or VirtualBox 7.2 — and QEMU is not the only one | Primary sources; the "what happens if you try Windows on VZEFIBootLoader" question is **unverified** — see §1.3 |
| 2 | macOS guest constraints | **Two** concurrent macOS VMs, enforced in the framework (`VZError` code 6) and rooted in the SLA; purposes limited to development, testing, macOS Server, or personal non-commercial use; service-bureau use excluded. One restore image can install many VMs. Apple-Account sign-in needs a Sequoia-or-later host *and* a VM created from a Sequoia-or-later image | Primary: Apple SLA PDF, Apple docs, Apple Support |
| 3 | Entitlements and distribution | `com.apple.security.virtualization` is **not** a restricted entitlement: Boolean, macOS 11+, no Apple approval documented. `com.apple.vm.networking` **is** restricted — "contact your Apple representative", not self-serve — and is needed only for **bridged** networking; NAT and host-only modes do not need it. No evidence of any conflict with Developer ID + hardened runtime + notarisation | Primary for both entitlements; "notarisation is unaffected" is **inference from absence** plus shipping precedent — see §3.3 |
| 4 | How the field does it | Two clusters. **Headless-only/CLI:** Lima, Colima, Tart (GUI optional), OrbStack, Vagrant. **Display-first:** UTM, VirtualBuddy, Parallels, VMware Fusion, VirtualBox. Every tool that runs Windows on Apple silicon is in the display-first cluster and none of them uses Virtualization.framework to do it | Primary docs per row |
| 5 | Cloud-image booting | Virtualization.framework accepts **RAW and ASIF only** — no qcow2, so conversion is required. Cloud images boot fine via `VZEFIBootLoader`; first-boot config is cloud-init, which is what Lima does. Tart instead distributes prebuilt VMs through OCI registries | Primary: Apple docs, Lima docs |

---

## 1. Guest OS support, precisely

### 1.1 What Apple documents

The framework overview states it is for "creating and managing virtual machines (VMs) on
Apple silicon and Intel-based Mac computers" and that it boots and runs "macOS or
Linux-based operating systems"
([Virtualization](https://developer.apple.com/documentation/virtualization)). macOS guests
are Apple-silicon-only and go through `VZMacPlatformConfiguration` + `VZMacOSBootLoader`;
everything else goes through `VZLinuxBootLoader` (kernel + initrd) or `VZEFIBootLoader`
(macOS 13+, any guest that expects an EFI ROM,
[VZEFIBootLoader](https://developer.apple.com/documentation/virtualization/vzefibootloader)).

Apple's own GUI-Linux sample confirms the ordinary desktop-VM shape is supported and
supported *well*: `VZEFIBootLoader`, an EFI variable store, the installer ISO attached as
a `VZUSBMassStorageDeviceConfiguration`, a graphics device, and Debian/Fedora/Ubuntu named
as tested distributions — with the explicit warning to use `aarch64`/`arm64` media on
Apple silicon
([Running GUI Linux in a virtual machine on a Mac](https://developer.apple.com/documentation/virtualization/running-gui-linux-in-a-virtual-machine-on-a-mac)).

Architecture is not translated. Lima documents the framework flatly as unable to "run
Intel guests on ARM hosts or vice versa"
([Lima: vz](https://lima-vm.io/docs/config/vmtype/vz/)). That is a property of the
hardware-assisted design, not a Lima limitation.

### 1.2 Nested virtualization

`VZGenericPlatformConfiguration.isNestedVirtualizationSupported` exists as of macOS 15.0
and is available on **M3 and later**
([isNestedVirtualizationSupported](https://developer.apple.com/documentation/virtualization/vzgenericplatformconfiguration/isnestedvirtualizationsupported)).
Tart's FAQ adds that in practice it is "only for Linux VMs" on M3/M4 with macOS 15+
([Tart FAQ](https://tart.run/faq/)). This matters for the M1 Mac mini peer named in
`CLAUDE.md`: it does not have it.

### 1.3 What happens if you point `VZEFIBootLoader` at a Windows-on-ARM image

**Unverified, and I want to be precise about the shape of the gap.** I found no credible
public report of anyone booting Windows under Virtualization.framework, and — equally —
no published account of a *specific* failure mode from someone who tried. Every
Windows-on-Apple-silicon path in the field routes around the framework rather than
through it. The two structural obstacles are documented independently of any attempt:

1. **No TPM.** Windows 11 requires TPM 2.0. The framework exposes no TPM device
   (see the correction section above). Lima's Windows 11 support required an external
   `swtpm` process, one per instance, over a Unix domain socket — and only with the QEMU
   driver ([Lima v2.2](https://www.cncf.io/blog/2026/07/28/lima-v2-2-windows-guests-and-tpm-2-0-emulation/)).
2. **Storage/network drivers.** The framework's devices are VIRTIO
   ([Virtualization](https://developer.apple.com/documentation/virtualization)). Windows on
   ARM has no in-box virtio-blk driver, so an unmodified installer would not see the boot
   disk. ARM64 virtio drivers do exist and are shipped by the virtio-win project — UTM's
   Windows guide instructs users to load `D:\NetKVM\w10\ARM64` — so this is a "supply the
   drivers at install time" problem rather than a hard wall, and Lima's QEMU-based Windows
   support downloads virtio drivers precisely for this. Whether the framework's specific
   ACPI/EFI presentation is otherwise acceptable to Windows is **unverified**.

Tooling built on the framework consistently declines Windows. UTM's documentation
describes its Apple Virtualization backend as supporting "only virtualization", "less
mature than QEMU", and "the only way to run macOS virtualized on Apple Silicon" — and its
Windows guests run on the QEMU backend
([UTM: Apple Virtualization settings](https://docs.getutm.app/settings-apple/virtualization/);
site blocks automated fetch, wording via search index).
VirtualBuddy states macOS 12+ and "some ARM-based Linux distros", no Windows
([VirtualBuddy](https://github.com/insidegui/VirtualBuddy)). Tart states macOS and Linux
([Tart quick start](https://tart.run/quick-start/)).

### 1.4 Is QEMU the only Windows route on Apple silicon? No — there are four

| Route | Engine | Status | Evidence |
|---|---|---|---|
| **QEMU** (usually via UTM) | `hvf` accelerator on Hypervisor.framework | Works for **Windows 11 ARM**. QEMU documents `hvf` as macOS-hosted, targeting x86 and Arm; anything the accelerator cannot take falls back to TCG, "purely emulated" | [QEMU accelerators](https://www.qemu.org/docs/master/system/introduction.html) |
| **Parallels Desktop** | Its own engine over Apple-silicon hardware-assisted virtualization | Works, and is the **only** virtualisation solution Microsoft authorises for Windows 11 Pro/Enterprise on Apple silicon | [Parallels KB 125343](https://kb.parallels.com/en/125343), [Microsoft support](https://support.microsoft.com/en-us/windows/experience/platform-variants/options-for-using-windows-11-with-mac-computers-with-apple-m1-m2-and-m3-chips) |
| **VMware Fusion** | VMware's Apple-silicon engine | Works for Windows 11 Arm, with reduced tooling: VMware Tools for Windows Arm provides a vmxnet3 driver and basic 2D only, and nested-virtualisation features (VBS, WDAG, WSL2) are unavailable | [Broadcom KB 315602](https://knowledge.broadcom.com/external/article/315602) |
| **VirtualBox 7.2** | Oracle's, on Arm64 hosts | Added Windows 11 Arm guests on macOS/Arm hosts in Aug 2025, with Guest Additions and a WDDM driver; Oracle frames Apple-silicon support as a developer preview not covered by Premier Support | [Oracle VirtualBox 7.2](https://blogs.oracle.com/virtualization/oracle-virtualbox-72) (site 403s to automated fetch; corroborated by [Neowin](https://www.neowin.net/news/virtualbox-72-finally-adds-support-for-windows-on-arm-guests/)) |

**x86 Windows is a separate and much worse story.** No Apple-silicon hypervisor
virtualises x86; Broadcom states plainly that "it is not possible to run x86 operating
systems in VMware Fusion VMs on Apple Silicon Mac systems"
([KB 315602](https://knowledge.broadcom.com/external/article/315602)), and QEMU on an Arm
host must fall back to TCG interpretation for an x86 target
([QEMU](https://www.qemu.org/docs/master/system/introduction.html)). Windows 11 Arm's own
x86 translation layer is the practical answer, and Microsoft notes 32-bit Arm Store apps
are not supported on M-series Macs
([Microsoft](https://support.microsoft.com/en-us/windows/experience/platform-variants/options-for-using-windows-11-with-mac-computers-with-apple-m1-m2-and-m3-chips)).

**What the QEMU route costs.** Three things, all of which land on Flotilla's existing
distribution plan rather than on its UI:

- **Hardened-runtime entitlements.** TCG is a JIT. Under the hardened runtime that
  requires `com.apple.security.cs.allow-jit` (or the weaker-still
  `allow-unsigned-executable-memory`), each a superset of the last
  ([Apple Developer Forums](https://developer.apple.com/forums/thread/776290)). By
  contrast, Virtualization.framework needs only `com.apple.security.virtualization` and no
  executable-memory relaxation.
- **Licensing.** QEMU is GPL-2.0. UTM ships Apache-2.0 with "(L)GPL components", gstreamer
  plugins statically linked, and QEMU-derived code
  ([UTM README](https://github.com/utmapp/UTM)). This project is personal and
  non-commercial, so the constraint is on redistribution mechanics, not on use.
- **Bundle size and build chain** — a QEMU build must be vendored, signed and notarised
  alongside the app. **Unverified:** I did not measure a notarised QEMU payload.

### 1.5 Windows licensing, separately from technology

Microsoft's position is explicit: Parallels Desktop 18/19/20 are the authorised solutions
for Arm Windows 11 Pro and Enterprise on M1–M3 Macs, and "a unique license is required for
each instance of Windows 11 Pro, either on hardware or in a virtual machine"; keys are
platform-agnostic between x64 and Arm
([Microsoft](https://support.microsoft.com/en-us/windows/experience/platform-variants/options-for-using-windows-11-with-mac-computers-with-apple-m1-m2-and-m3-chips)).
Parallels advertises the same authorisation, extended to M4/M5
([Parallels](https://www.parallels.com/products/desktop/microsoft-authorized-solution-windows-11-arm/)).
Running Windows 11 Arm under UTM/QEMU or VirtualBox is technically possible and outside
that authorisation.

---

## 2. macOS guest constraints

### 2.1 The two-VM limit, and where it actually comes from

It is a licence term that Apple then enforces in code. Section 2B(iii) of the macOS SLA
grants you the right

> "to install, use and run up to two (2) additional copies or instances of the Apple
> Software, or any prior macOS or OS X operating system software or subsequent release of
> the Apple Software, within virtual operating system environments on each Apple-branded
> computer you own or control that is already running the Apple Software, for purposes of:
> (a) software development; (b) testing during software development; (c) using macOS
> Server; or (d) personal, non-commercial use."

I extracted that verbatim from Apple's own PDFs and confirmed the wording is **identical**
in both [macOS Sequoia](https://www.apple.com/legal/sla/docs/macOSSequoia.pdf) and
[macOS Tahoe](https://www.apple.com/legal/sla/docs/macOSTahoe.pdf) (§2B(iii) in each).

Two restrictions in the same clause matter for anything fleet-shaped:

- the grant "does not permit you to use the virtualized copies or instances of the Apple
  Software in connection with service bureau, time-sharing, terminal sharing, relay
  service or other similar types of services";
- iOS, iPadOS, watchOS and tvOS may not be virtualised on a Mac at all.

The framework enforces the count. `VZError.Code.virtualMachineLimitExceeded` — "Unable to
create an additional VM", macOS 12+ — fires when starting a VM "would exceed the system's
limit on the number of simultaneously running virtual machines"
([Apple](https://developer.apple.com/documentation/virtualization/vzerror/code/virtualmachinelimitexceeded)).
In practice that surfaces as `VZErrorDomain` code 6 on the third macOS guest, and the
limit is not a resource constraint — an Ultra with 128 GB hits it with capacity to spare
([Eclectic Light](https://eclecticlight.co/2022/08/04/virtualisation-on-apple-silicon-macs-8-how-apple-limits-vms/),
corroborated by an [Apple developer forum report](https://developer.apple.com/forums/thread/729580)
on an M1 Ultra/128 GB).

**Unverified:** whether Linux guests count toward the same cap. Apple's error description
is written generically ("virtual machines"), while Eclectic Light suspects Linux VMs are
unlimited and says so as a suspicion, not a finding. This is worth one empirical test on
the M1 mini before anyone designs around either answer.

### 2.2 Guest versions

Apple silicon can virtualise **macOS 12 (Monterey) and later only** — not Big Sur, not
Intel macOS — because Virtio guest support was built into macOS starting at Monterey
([Eclectic Light](https://eclecticlight.co/2026/04/29/virtualisation-on-apple-silicon-macs-is-different/)).
Tart states the same practical range, Monterey (12) through Tahoe (26)
([Tart](https://tart.run/quick-start/)).

### 2.3 Restore images — one download, many VMs

`VZMacOSRestoreImage` is obtained either from Apple over the network
(`latestSupported` / `fetchLatestSupported`) or loaded from a local IPSW file; **loading a
restore image at all requires the `com.apple.security.virtualization` entitlement**
([VZMacOSRestoreImage](https://developer.apple.com/documentation/virtualization/vzmacosrestoreimage)).

A restore image is **not** per-VM. Apple's installation article describes creating a
separate `VZVirtualMachineConfiguration` per VM against the same restore-image URL; what
must be unique per VM is the machine identifier and the auxiliary storage. Installation
requires a stopped VM, a hardware model the host supports
(`mostFeaturefulSupportedConfiguration`), and configuration meeting the image's minimum
CPU and memory; pausing or stopping mid-install is "undefined behavior"
([Installing macOS on a virtual machine](https://developer.apple.com/documentation/virtualization/installing-macos-on-a-virtual-machine)).

### 2.4 Disk space

Apple gives no recommendation in the installation article. The observable numbers:
Apple's own macOS sample creates a **128 GB** disk image
([Running macOS in a virtual machine on Apple silicon](https://developer.apple.com/documentation/virtualization/running-macos-in-a-virtual-machine-on-apple-silicon));
Tart's prebuilt macOS Sonoma + Xcode image is **54 GB compressed** to pull, against
**~0.9 GB** for an Ubuntu image and a 20 GB default Linux disk
([Tart](https://tart.run/quick-start/), [Tart FAQ](https://tart.run/faq/) — Tart
auto-prunes least-recently-used cached VMs when space runs low). **Unverified:** the size
of a bare macOS IPSW; I did not confirm one.

### 2.5 Apple Account, iCloud and activation

Signing a macOS guest into an Apple Account is possible but fenced:

- the **host** must be running macOS Sequoia or later
  ([Apple Support: Use iCloud on a virtual machine](https://support.apple.com/en-us/120468));
- the **VM** must have been created from a Sequoia-or-later install image — a VM *upgraded*
  to Sequoia does not qualify;
- the identity is derived from the **host's Secure Enclave**, so moving the VM to a
  different Mac or a different user causes macOS to mint a new identity and demand
  re-authentication
  ([Eclectic Light](https://eclecticlight.co/2024/06/17/how-sequoia-changes-virtualisation-on-apple-silicon/)).

That last point is the one with fleet consequences: a macOS VM is not a portable artefact
once it is signed in.

Independently of Apple Account, **most Mac App Store apps do not run in a VM** because of
authentication restrictions, Wi-Fi is presented as Ethernet only, and audio support is
limited
([Eclectic Light](https://eclecticlight.co/2026/04/29/virtualisation-on-apple-silicon-macs-is-different/)).

---

## 3. Entitlements and distribution

This is the section that touches `DECISIONS.md` item 13 and Q9, so I have separated what
is documented from what is inferred.

### 3.1 `com.apple.security.virtualization` — ordinary

A Boolean "that indicates whether your app can use the Virtualization framework", macOS
11.0+. The documentation names no approval process, no restriction, and no provisioning
requirement. It tells you to check `VZVirtualMachine.isSupported` for hardware capability
and to call `VZVirtualMachineConfiguration.validate()` to check "for the availability of
the entitlement the framework requires"
([com.apple.security.virtualization](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.virtualization)).

What does matter is signing with a real identity. A developer reported a CLI carrying the
entitlement working locally and failing on another machine with "The process doesn't have
the 'com.apple.security.virtualization' entitlement"; the cause was ad-hoc / Personal Team
signing, resolved by signing with a proper developer account
([Apple Developer Forums 698220](https://developer.apple.com/forums/thread/698220)).
Flotilla's current ad-hoc signature from `Scripts/make-app.sh` is exactly that shape of
build.

### 3.2 `com.apple.vm.networking` — restricted, and only for bridging

Apple's own documentation is unambiguous: the entitlement covers managing virtual network
interfaces without escalating to root, is required for the
[vmnet APIs](https://developer.apple.com/documentation/vmnet), and is **"restricted to
developers of virtualization software"** — "to request this entitlement, contact your Apple
representative"
([com.apple.vm.networking](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.vm.networking)).
It is not self-serve.

The scope is narrower than the name suggests. It is needed for
`VZBridgedNetworkDeviceAttachment`, which "interacts directly with a physical network
interface on the host"
([VZBridgedNetworkDeviceAttachment](https://developer.apple.com/documentation/virtualization/vzbridgednetworkdeviceattachment)).
NAT (`VMNET_SHARED_MODE`) and host-only (`VMNET_HOST_MODE`) do **not** require it — a point
made in the field by projects that hit the wall, including Tart
([tart#243](https://github.com/cirruslabs/tart/issues/243)) and QEMU
([qemu#1364](https://gitlab.com/qemu-project/qemu/-/issues/1364)).

This is the same conclusion [VM-SECURITY-REVIEW.md](VM-SECURITY-REVIEW.md) reaches from
the security side.

### 3.3 Notarisation — no evidence of conflict, and here is exactly how strong that is

**Verified:** Notarisation requires Developer ID signing and the hardened runtime, and
forbids `com.apple.security.get-task-allow`; Apple's guidance is to take only the
entitlements you need
([Apple, New Notarization Requirements](https://developer.apple.com/news/?id=04102019a)).
Apple's Developer ID support page names *advanced capabilities such as CloudKit* as the
case needing a Developer ID provisioning profile
([Developer ID](https://developer.apple.com/support/developer-id/)) — virtualization is not
in that class of capability.

**Inference, not a quotation:** I could not find an Apple statement that says in so many
words "the virtualization entitlement needs no profile and does not affect notarisation."
The conclusion rests on (a) the entitlement documentation carrying no restriction language
where `com.apple.vm.networking`'s carries it explicitly, and (b) shipping precedent —
UTM, VirtualBuddy and Tart are all distributed as signed Developer ID Mac apps carrying
the entitlement. Given this project's history with plausible-sounding detail, the
honest label is: **strongly supported, not quoted.** The cheap way to close it is to build
one Developer ID + hardened-runtime binary with the entitlement and put it through
`notarytool`; that is a one-afternoon empirical answer, not a research question.

Note also that this is the one entitlement axis where the QEMU route is *worse* and the
Virtualization.framework route is clean: no JIT relaxation is needed (§1.4).

### 3.4 If Flotilla ever sandboxes (it does not today, Q9)

Sandboxing does not block the framework. UTM ships on the Mac App Store — necessarily
sandboxed — with feature parity claimed against the GitHub build, the sandbox costing file
reach rather than virtualisation: no direct mounting of external disks (disk images only),
no drag and drop, and new VMs created inside the app sandbox container
([UTM: macOS installation](https://docs.getutm.app/installation/macos/); site 403s to
automated fetch, wording via search index).

So the App Sandbox tax on a VM host is about **where guest disk images and installer media
may live** — user-selected files, security-scoped bookmarks, container storage — not about
whether VMs may run. That interacts with `MountPolicy` in an obvious way and is worth
noting, not resolving here.

Two things I did **not** verify: whether an App Store review would accept a general-purpose
VM host from this project at all, and whether the restricted `com.apple.vm.networking` is
obtainable by a personal, non-commercial developer. Both are **unverified**.

---

## 4. How the field does it

| Tool | Hypervisor / engine | Guests | Headless or GUI | How a VM is created | Licence |
|---|---|---|---|---|---|
| **UTM** | QEMU (+ Hypervisor.framework accel) **and** Virtualization.framework as a second backend | Windows, Linux, macOS, plus 30+ emulated architectures | **Display-first** (also scriptable) | ISO/installer media; macOS via Virtualization.framework | Apache-2.0 frontend with (L)GPL/QEMU-derived components ([README](https://github.com/utmapp/UTM)) |
| **Tart** | Virtualization.framework | macOS 12–26, Linux (Ubuntu/Debian/Fedora) | GUI window by default (`tart run`); built for CI, so **headless-leaning** | `tart create --linux`, boot an ISO; or **pull prebuilt VMs from any OCI-compatible registry** | Functional Source License FSL-1.1-ALv2 → Apache-2.0 after 2 years; free for personal use, paid above 100 CPU cores ([LICENSE](https://github.com/cirruslabs/tart/blob/main/LICENSE), [licensing](https://tart.run/licensing/)) |
| **Lima** | `vz` (Virtualization.framework, **default on macOS since v1.0**), `qemu`, `wsl2`, `krunkit` | Linux; experimentally macOS (v2.1, `vz`), FreeBSD, Windows 11 / Server 2025 (v2.2, **QEMU only**) | **Headless-only**, `limactl` CLI | Cloud images + cloud-init; Windows via unattended XML answer file | Apache-2.0 ([LICENSE](https://github.com/lima-vm/lima/blob/master/LICENSE)) |
| **Colima** | Lima underneath; `vz` and `krunkit` VM types | Linux | **Headless-only**, CLI | `colima start`; container-runtime oriented | MIT ([README](https://github.com/abiosoft/colima)) |
| **Vagrant** | None of its own — a provider abstraction | Whatever the provider supports | **Headless-first** by convention | `Vagrantfile` + boxes | Vagrant is BUSL-1.1 since 2023 (**unverified** — I did not confirm the current licence from HashiCorp) |
| **OrbStack** | Custom VMM/virtualisation stack, not Virtualization.framework | Linux only (16 distros), sharing **one kernel** across machines, WSL2-style | **Headless**, CLI + management GUI | `orb create <distro>` from distro images | Free for personal, non-commercial use; per-user licence for commercial ([licensing](https://docs.orbstack.dev/licensing)) |
| **Parallels Desktop** | Own engine over Apple-silicon hardware-assisted virtualization | Windows 11 Arm (Microsoft-authorised), Linux Arm; x86 VMs from Intel Macs do not carry over | **Display-first** | Installer media, guided wizards | Commercial, subscription ([KB 125343](https://kb.parallels.com/en/125343)) |
| **VMware Fusion** | VMware's Apple-silicon engine | Arm64 guests only: Ubuntu, Debian, RHEL, Fedora, FreeBSD, Windows 11 Arm. **macOS guests never supported on Apple silicon** | **Display-first** | ISO / installer media | Free for personal, educational **and commercial** use since 11 Nov 2024 ([Broadcom](https://blogs.vmware.com/cloud-foundation/2024/11/11/vmware-fusion-and-workstation-are-now-free-for-all-users/), [KB 315602](https://knowledge.broadcom.com/external/article/315602)) |
| **VirtualBox 7.2** | Oracle's own, Arm64 hosts | Linux/BSD Arm, and **Windows 11 Arm** as of 7.2 | **Display-first** | ISO / installer media | GPL-2.0 core; Apple-silicon support framed as developer preview ([Oracle](https://blogs.oracle.com/virtualization/oracle-virtualbox-72)) |

Two supporting details for the Vagrant row: **VirtualBox was for years unusable on Apple
silicon**, which is why the Apple-silicon Vagrant ecosystem settled on the VMware and
Parallels providers; and Cirrus Labs ships
[`vagrant-tart`](https://github.com/cirruslabs/vagrant-tart), a Vagrant provider backed by
Tart and therefore by Virtualization.framework.

### 4.1 The axis the owner asked about

The split is clean, and it is not primarily a technical one:

- **Headless-only / CLI-first** — Lima, Colima, OrbStack, Vagrant, and Tart in its intended
  CI role. These exist to give you a Linux userland or a build agent. The VM is
  infrastructure; nobody looks at it. They lean on cloud images, cloud-init, SSH and port
  forwarding, and their UI surface is a table of instances and their state.
- **Display-first** — UTM, VirtualBuddy, Parallels, VMware Fusion, VirtualBox. These exist
  to give you a *screen*. They consume installer ISOs and restore images, own a window,
  and take on guest tooling, clipboard, shared folders, display resizing and 3D.

Virtualization.framework serves both: `VZGraphicsDisplay` and runtime display
reconfiguration are there for the second cluster
([Apple](https://developer.apple.com/documentation/virtualization/vzgraphicsdisplay)), and
Lima drives the identical framework with no display at all. The choice of cluster is a
product decision, not a capability constraint — with one exception worth stating plainly:
**every product in the field that runs Windows is display-first, and none of them reaches
Windows through Virtualization.framework.**

---

## 5. Cloud-image booting

### 5.1 Disk format: conversion is required for qcow2

Virtualization.framework supports exactly two disk formats, per
[VZDiskImageStorageDeviceAttachment](https://developer.apple.com/documentation/virtualization/vzdiskimagestoragedeviceattachment):

- **RAW** — "a 1-to-1 mapping between the offsets in the file and the offsets in the VM disk";
- **ASIF** (Apple Sparse Image Format) — occupies space proportional to real data and
  transfers efficiently between hosts because its structure does not depend on the host
  file system.

**qcow2 is not supported.** So a Fedora qcow2 cloud image must be converted before it can
be attached; an Ubuntu cloud image already published in raw form can be attached directly.

ASIF arrived with macOS Tahoe and Apple recommends migrating VM storage from RAW to it.
**Partly unverified:** secondary reporting says Tahoe can *create* ASIF while Sequoia 15.5
can mount but not create, with the backward-compatibility floor unstated by Apple
([Eclectic Light](https://eclecticlight.co/2025/06/12/macos-tahoe-brings-a-new-disk-image-format/),
[Computerworld](https://www.computerworld.com/article/4007567/wwdc-what-is-apple-sparse-image-format-asif.html));
I did not confirm the creation/mount split from Apple.

### 5.2 Booting: yes, via EFI

A standard Arm64 cloud image is EFI-bootable, and `VZEFIBootLoader` plus an EFI variable
store is precisely the supported configuration
([Apple's GUI Linux sample](https://developer.apple.com/documentation/virtualization/running-gui-linux-in-a-virtual-machine-on-a-mac)).
The older alternative — `VZLinuxBootLoader` with an externally supplied kernel and initrd —
still exists but requires extracting them from the image.

Lima documents the `vz` driver's real edges: no legacy BIOS mode (so CentOS Stream and
Oracle Linux 8 fail on Intel Macs), no cross-architecture guests, and no kernel boot
messages in the serial log
([Lima: vz](https://lima-vm.io/docs/config/vmtype/vz/)).

### 5.3 What Lima does

Lima is the reference implementation of the cloud-image path. It boots distro cloud images
and requires the guest to provide **cloud-init**, along with systemd or OpenRC, sudo,
sshfs and newuidmap/newgidmap; Ubuntu is the default and AlmaLinux, Alpine, Arch, Debian,
Fedora, openSUSE, Oracle Linux and Rocky are known to work
([Lima FAQ](https://lima-vm.io/docs/faq/), [Lima docs](https://lima-vm.io/docs/)).

For the format mismatch it converts rather than avoids: with `vmType: vz`, qcow2 disks are
converted to RAW on boot because the framework mounts RAW only, and the image downloader
produces a converted copy on demand when the cached artefact is not in a format the driver
supports
([Lima vz driver internals](https://deepwiki.com/lima-vm/lima/10.2-vz-driver-(macos-virtualization.framework)) —
DeepWiki is a derived source, so treat the mechanism as documented and the wording as
secondary; the user-visible consequence is corroborated by
[lima#1964](https://github.com/lima-vm/lima/issues/1964)). Lima's own `limactl disk create`
offers qcow2 (default) and raw
([Lima: disk](https://lima-vm.io/docs/config/disk/)).

### 5.4 What Tart does

Tart sidesteps first-boot provisioning entirely. For Linux it creates a blank VM and boots
installer media — `tart create --linux ubuntu` then `tart run --disk <iso> ubuntu`, 20 GB
default disk — and for reuse it **pushes and pulls whole VMs through OCI-compatible
registries** with `tart push` / `tart pull` / `tart clone`, credentials in the Keychain
([Tart quick start](https://tart.run/quick-start/)). That is a different distribution model
from Lima's: prebuilt golden images over a registry versus a cloud image plus cloud-init.

---

## What this rules in and out

### Technically available with Virtualization.framework alone

- **Linux guests on Apple silicon, Arm64**, booted from ISO installer media or from a
  cloud image via `VZEFIBootLoader`, with VIRTIO storage, networking, entropy, sockets,
  memory ballooning and file sharing.
- **Either shape of product** — headless like Lima, or with a real display like UTM.
  `VZGraphicsDisplay` (macOS 14+) supports runtime display reconfiguration; Linux GUI needs
  `VZVirtioGraphicsDeviceConfiguration` (macOS 13+).
- **macOS guests on Apple silicon, macOS 12 through 26**, installed from an Apple-fetched
  or local IPSW restore image, one image serving many VMs.
- **NAT and host-only networking**, with no restricted entitlement.
- **Developer ID signing, hardened runtime and notarisation**, needing only
  `com.apple.security.virtualization` and no executable-memory relaxation — subject to the
  one empirical check named in §3.3.
- **Nested virtualization**, on M3 and later with macOS 15+, and per Tart for Linux guests
  only. Not on the M1 mini.
- **App Sandbox compatibility** if that ever changes (Q9), at the cost of file-reach
  restrictions on guest images and installer media.

### Available, but capped or conditioned

- **At most two concurrent macOS VMs.** Enforced by the framework, rooted in SLA §2B(iii),
  identical in the Sequoia and Tahoe agreements. Not tunable.
- **macOS VM purposes are enumerated by licence**: development, testing during development,
  macOS Server, or personal, non-commercial use — and explicitly *not* service bureau,
  time-sharing, terminal sharing or relay services. A personal, non-commercial project sits
  inside that grant; anything that serves macOS guests to other people over the wire needs
  a licensing read, not an engineering read.
- **Apple Account / iCloud in a macOS guest** requires a Sequoia-or-later host and a VM
  built from a Sequoia-or-later image, with the identity bound to the host's Secure
  Enclave — so a signed-in macOS VM is not portable between Macs.
- **Cloud images in qcow2** need conversion to RAW or ASIF first.

### Ruled out — for a Virtualization.framework-only app

- **Windows guests of any kind.** No Windows boot path is documented, there is no TPM
  device for Windows 11's requirement, and no public report exists of anyone making it
  work. Adding Windows means adding a second engine.
- **x86 guests on Apple silicon.** No hypervisor on this hardware virtualises x86; QEMU
  can only interpret, and Broadcom states the impossibility outright for Fusion.
- **More than two macOS VMs.**
- **Bridged networking**, until Apple grants `com.apple.vm.networking` — restricted to
  virtualisation developers, by request to an Apple representative, not self-serve.
- **Attaching qcow2 images directly.**
- **Big Sur or Intel macOS guests.**

### Ruled out unless a second engine is adopted

QEMU is the route to Windows 11 Arm without Parallels, and it brings: a JIT entitlement
that weakens the hardened runtime, GPL-family components to vendor and notarise, TCG-speed
x86 emulation if x86 is ever wanted, and — for Windows 11 specifically — an external
`swtpm` process, exactly as Lima v2.2 does it. Parallels remains the only
Microsoft-authorised path regardless of engine.

### The open questions, restated as tests rather than research

1. Do **Linux** VMs count against the two-VM framework limit? One empirical test on the M1
   mini settles it.
2. Does a Developer ID + hardened-runtime build carrying
   `com.apple.security.virtualization` pass `notarytool` unchanged? One build settles it.
3. Would Apple grant `com.apple.vm.networking` to a personal, non-commercial developer?
   Only asking settles it — and per
   [VM-SECURITY-REVIEW.md](VM-SECURITY-REVIEW.md), bridged networking is release-blocked
   until it does.
4. What is the notarised size and build cost of a vendored QEMU? Unmeasured here.
