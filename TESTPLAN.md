# Flotilla 1.5.0.0-beta.2 — test plan

Written 8 October 2026 for beta 2, from scratch: almost everything has changed since beta 1
(5 September), so nothing here assumes beta 1's plan or results.

**How to use it.** Each case has an ID to quote back, what to do, and what should happen. Mark each
**PASS**, **FAIL** (say what happened instead) or **BLOCK** (could not get far enough to try). A
screenshot beats a description. Anything surprising that is not a case is still worth reporting.

**What you need.**

- **Admin Mac:** Apple silicon, macOS 26 or later, the beta 2 `.pkg`. Ideally a Mac — or a VM — that
  has never had Flotilla or `container` on it, for the first-run cases (section 1).
- **Two hosts** for sections 10–14: Macs or VMs on the same network, macOS 26 or later. One should
  start **without** `container` installed (case 12.4). Someone has to be at each host once, to answer
  macOS's prompts.
- An internet connection (image pulls, Docker Hub search, the `container` download).

Running containers on the test Macs may be stopped by some cases — each such case says so.

---

## 1. Install and first run (one Mac, nothing installed)

| ID | Do | Expect |
|---|---|---|
| 1.1 | Open the `.pkg` and install. | Installs with no Gatekeeper warning (signed and notarised). Flotilla is in /Applications. |
| 1.2 | Open Flotilla for the first time. | Onboarding asks for an appearance and how to use this Mac — choose **Admin** for this pass (Host has its own section, 10) — then offers **Download and Install container 1.5.0**. |
| 1.3 | Choose Download and Install. | Overview's banner shows each step — downloading, checking it is Apple's, Apple's Installer, starting, the kernel — and so does the status line at the bottom left. Your password is asked by macOS's Installer, not Flotilla. |
| 1.4 | Carry on after the install. | The kernel downloads by itself (about 20 s), then the runtime starts and the banner goes. Overview shows a **Get started** card with Run a Container… (in colour), Pull Image…, Add Host… and Try a Suggested Stack…. |
| 1.5 | Quit and reopen. | No onboarding. Get started still shows until something is created. |
| 1.6 | Settings ▸ Advanced ▸ **Flotilla Helper** ▸ Install…. | macOS lists Flotilla in Login Items & Extensions; Settings says *Waiting for your approval* and offers **Open Login Items…**. Switch it on: Settings says **On**. |

## 2. Menu bar

| ID | Do | Expect |
|---|---|---|
| 2.1 | Look at the menu bar icon. | Three sails in a rounded square, the same colour as the other menu bar icons — check with Flotilla set to Light, Dark and Auto (the sun button in the window bar). |
| 2.2 | With container running and nothing wrong. | Green dot on the icon. |
| 2.3 | In Terminal, `container system stop`. | Within a few seconds: a red no-entry badge, and Overview says *container is stopped on This Mac* with **Start**. Press Start: back to green. Stops running containers. |
| 2.4 | Open the menu. | Status line (e.g. *Container system running*), Open Flotilla, Hosts ▸, Run Container…, Pull Image…, Settings…, Troubleshoot ▸, About Flotilla, Check for Updates…, Quit Flotilla with *Containers keep running*. |
| 2.5 | Troubleshoot ▸ Restart Container System…. | Asks first, saying running containers stop. Cancel does nothing; Restart restarts. |
| 2.6 | Each menu item. | Opens the matching place in the window, even with the window closed. |

## 3. Overview

| ID | Do | Expect |
|---|---|---|
| 3.1 | Open Overview with nothing wrong. | One line *Nothing needs attention…*, then Across all hosts (Containers, Images, Volumes, Networks), then the Hosts table. |
| 3.2 | Make something need attention (2.3, or a host offline in 13.4). | A Needs attention list at the top; each item opens the section that deals with it. |
| 3.3 | Hosts table ▸ the columns button. | Show/hide Model, CPU, Memory, Disk, macOS, Flotilla, container, Last Check-in; Host cannot be hidden; the choice survives a relaunch. |
| 3.4 | Read the CPU column. | `M1 · 8 cores`; a virtual Mac shows `vCores`; no "Apple". |
| 3.5 | Click a host name. | Opens that host's page under Hosts. |
| 3.6 | Click This Mac, then Pressure ▸ 5m, 15m and 1h. | The graph's time axis spans the chosen range; the header says how much history has been collected so far. |

## 4. Containers and groups

| ID | Do | Expect |
|---|---|---|
| 4.1 | Run a Container… with an image, a name, a published port and a command with quotes. | Created and running; the command keeps its quoted argument as one. |
| 4.2 | Start, stop, restart, delete from the row and from the ⋯ menu. | Same choices in both; delete asks first. |
| 4.3 | Select several, use the bulk bar. | Acts on all selected. |
| 4.4 | Suggestions ▸ a stack. | Creates a group with its containers and network. Group row shows *N of M running* and a half dot when mixed; expanding shows members. |
| 4.5 | Delete a group both ways. | *Delete group* leaves its containers; *Delete group and containers* names every container before deleting. |
| 4.6 | Logs and Terminal on a running container. | Logs stream; the terminal opens a shell. |
| 4.7 | On a running container with a published port: ⋯ ▸ Run Again with Changes…. | The form is filled in from it; the port still in use is left out and named. The new container starts and stays running. |

## 5. Images and registries

| ID | Do | Expect |
|---|---|---|
| 5.1 | Images ▸ **Browse Docker Hub** (magnifying glass). | Docker Official Images listed. Type `redis`: results, with the official `redis` chosen and its tags on the right, `latest` selected. Hardened Image and MCP listings greyed with a reason. |
| 5.2 | Press **Pull redis:latest…**. | The Pull form opens filled in; Pull downloads with progress. |
| 5.3 | Pull form ▸ *Browse Docker Hub* link. | Opens the same in-app page, not the website. |
| 5.4 | Build Image from Dockerfile…. | Builds; the image appears. |
| 5.5 | Registries ▸ add a registry and sign in. | Sign-in is stored by `container`/the Keychain; nothing about it appears in Flotilla's files. |
| 5.6 | Settings ▸ About ▸ network list. | Lists Sparkle updates, Docker Hub search, Apple's container CLI and your other Macs, each with when. |

## 6. Volumes and networks

| ID | Do | Expect |
|---|---|---|
| 6.1 | Create, inspect and delete a volume and a network. | Each works; delete asks first. |
| 6.2 | A network that lost its bridge (if it happens). | A banner with Restart container…, which asks first. |

## 7. DNS

| ID | Do | Expect |
|---|---|---|
| 7.1 | DNS ▸ New Domain… with the Flotilla Helper on. | Flotilla asks to confirm; no password. The domain works for a container created afterwards. |
| 7.2 | The same with the helper removed. | macOS asks for an administrator password instead. |
| 7.3 | Try a reserved name such as `local`. | Refused with a reason. |

## 8. Machines and clusters

| ID | Do | Expect |
|---|---|---|
| 8.1 | New Machine…; start, stop, delete. | Works; delete asks first. |
| 8.2 | New Cluster…; Recreate…. | Creates; Recreate warns it destroys the cluster's data, then recreates with the same settings. |
| 8.3 | New Machine… ▸ the image choices. | Only images that boot as a machine are offered (no Ubuntu, Debian or Fedora). |

## 9. Settings, export and import

| ID | Do | Expect |
|---|---|---|
| 9.1 | Each Settings tab. | Every control does something; nothing is a placeholder. |
| 9.2 | Themes: each bar colour, light and dark. | Bar and background change; controls stay macOS-native. |
| 9.3 | File ▸ Export Configuration…, then Import on another Mac. | Groups, tags, networks, volumes and (if ticked) hosts and settings come across; secrets never do. |
| 9.4 | Help ▸ Create Support Bundle…. | Saves a bundle; it contains no secrets or personal paths — search it for your short username. |
| 9.5 | Settings ▸ General ▸ Launch at login: on, then restart the Mac. | Flotilla opens at login and is listed in System Settings ▸ Login Items. Turn it off and restart: it doesn't. |

## 10. Pairing hosts

| ID | Do | Expect |
|---|---|---|
| 10.1 | On a host: Settings ▸ Host Mode ▸ turn it on. | The host shows its fingerprint. macOS may ask to allow Flotilla on the local network — **allow it** (a host cannot be reached until someone does). |
| 10.2 | On the admin: Hosts ▸ + ▸ Add Host…. | The host is found; the fingerprints match on both screens; pairing completes after approval. |
| 10.3 | Pair a second host. | Both show in Hosts and in Overview, connected. |
| 10.4 | Remove Access on one host, then pair it again. | Removal cuts it off; re-pairing works. |

## 11. Working across Macs

| ID | Do | Expect |
|---|---|---|
| 11.1 | Pull Image… ▸ Pull to: tick both hosts. | Each Mac pulls; progress per Mac. |
| 11.2 | An image on This Mac ▸ Send to Hosts…. | The image arrives on the chosen hosts. |
| 11.3 | Run a container on a host (Run form ▸ host). | Created there; listed with that host in Containers. |
| 11.4 | Logs ▸ Live on a host's container. | Lines stream from the host. |
| 11.5 | A network ▸ Push to Hosts…. | Created on each host from that host's own address block. |

## 12. The Flotilla Helper and container on hosts

| ID | Do | Expect |
|---|---|---|
| 12.1 | On each host: install the Flotilla Helper (1.6). | On the admin, DNS ▸ + ▸ Set Up Zones… lists that host as one that can be ticked; with its helper off it is greyed with the reason. |
| 12.2 | DNS ▸ + ▸ Set Up Zones…. | Each Mac says what setting up would do and how many containers its restart stops; set up two Macs. |
| 12.3 | Names across Macs: turn on, publish a port on a host's container. | From the admin, `curl http://<name>.<host zone>:<port>` answers. An unpublished container says why it isn't reachable. |
| 12.4 | The host without container: turn host mode on. | It installs container 1.5.0 and its kernel by itself, through its helper. |
| 12.5 | Overview ▸ Updates, if a host's container is older. | *N hosts can upgrade container…*; Upgrade asks first with the number of containers it stops. |

## 13. Updates

| ID | Do | Expect |
|---|---|---|
| 13.1 | Install a newer build on the admin. | Hosts update themselves one at a time; Overview ▸ Updates shows *Updating Flotilla on 1 host…*; running containers keep running. |
| 13.2 | Turn automatic host updates off; install a newer build. | Hosts wait; Updates offers **Update N Hosts Now**. |
| 13.3 | Flotilla ▸ Check for Updates… on the admin. | Sparkle checks melonfleet.github.io. Until the first release is published it says it can't reach the update feed; once one is, it says Flotilla is up to date or offers the newer build. |
| 13.4 | Turn a host off. | Within a minute: not answering in Overview, the badge turns red, Last Check-in stops and turns amber. Turn it on: recovers by itself. |
| 13.5 | A host where Flotilla was installed from the `.pkg`, with its Flotilla Helper on: install a newer build on the admin. | The host updates like the others (its helper installs it, the app stays owned by root). With the helper off, Hosts says why it can't update and how to. |

## 14. Uninstall and reset

| ID | Do | Expect |
|---|---|---|
| 14.1 | Remove the Flotilla Helper in Settings, then delete the app. | Login Items no longer lists Flotilla. |
| 14.2 | Apple's `uninstall-container.sh -k`, then reopen Flotilla. | Flotilla offers to install container again (1.2). |

---

## Known limits in beta 2

- A new host needs one click on macOS's local-network prompt; a configuration profile cannot grant it (Apple TN3179).
- Containers on different Macs reach each other only through published ports; there is no shared network between Macs.
- The Docker Hub browser searches Docker Hub only; GitHub's registry has no public search.
- Sparkle updates appear only once a release is published.
