# Testing the Flotilla beta

Thank you for helping. This page covers **Flotilla 1.5.0-beta.5**, tested with Apple's `container`
1.5.0.

**This test is for people who have never used Flotilla,** on a Mac that has never had it. We want to
know what someone sees the first time: what was clear, what wasn't, and what went wrong. You don't need
to know anything about containers. If you've used Flotilla before, you're still welcome: say so in your
reports, and see [If you used an earlier beta](#if-you-used-an-earlier-beta) at the end.

The step-by-step test plan is at **[melonfleet.dev/flotilla/beta](https://melonfleet.dev/flotilla/beta/)**.
It has Pass, Fail and Skip buttons, remembers where you got to, asks for your first impressions along
the way, and fills in a report for you when a step fails.

**Before you start, be signed in to GitHub in your browser.** A free account is enough. Each Fail
opens a prefilled GitHub issue, and you submit it yourself.

## What Flotilla is, in one paragraph

Apple's `container` is a free tool from Apple that runs Linux *containers* on a Mac: small,
self-contained programs, such as a web server or a database, packaged with everything they need. Each
one runs in its own lightweight Linux virtual machine. `container` is used by typing commands in
Terminal. Flotilla is a Mac app that does the same with windows and buttons, and can also look after
other Macs from one Mac. You don't need Terminal for this test.

## What you need

- A Mac with Apple silicon (M1 or later), running macOS 26 or later.
- About 30 minutes for the core path, and a few GB of free disk space.
- An administrator password for the Mac, to install Flotilla's helper and Apple's `container`.
- A free GitHub account, to file reports.
- A Mac where a test app doesn't matter. Flotilla never removes anything you didn't ask it to, but
  this is a beta.
- Optional: a second Apple silicon Mac, for the tests where one Mac looks after another.

You don't need `container` installed first. If it's missing, Flotilla offers to download Apple's own
signed package and hand it to Apple's Installer. It never installs anything without asking.

## Installing

Download from the [1.5.0-beta.5 release](https://github.com/melonfleet/flotilla/releases/tag/v1.5.0-beta.5),
under **Assets**. Every file is signed with a Developer ID and notarised by Apple.

- **Disk image (most people):** open `Flotilla-1.5.0-beta.5.dmg` and drag Flotilla to the
  Applications folder in the window that opens.
- **Package:** open `Flotilla-1.5.0-beta.5.pkg` and follow Apple's Installer. This is the one for MDM
  and scripted installs. It refuses to install on macOS earlier than 26.

Open Flotilla from Applications. The first time, macOS should ask only its usual question about an app
downloaded from the internet, with an **Open** button. (After the package, it may not ask at all.) Any
"unidentified developer", "can't be opened" or "damaged" warning is a bug: report it.

Flotilla then opens its **Setup Assistant**, a short guide through the first choices. The test plan
walks you through it.

**During setup, macOS may ask you to allow the Flotilla Helper** in System Settings ▸ General ▸ Login
Items & Extensions. Please approve it. It's a small background service for the few jobs that need
administrator rights (installing `container`, DNS names across Macs, updating Flotilla on other Macs),
and without it those can't run.

To hear about new betas, go to [github.com/melonfleet/flotilla](https://github.com/melonfleet/flotilla)
and choose Watch ▸ Custom ▸ Releases.

## What to test

The [test plan](https://melonfleet.dev/flotilla/beta/) is in two parts:

- **The core path, under 30 minutes:** download and install, the first launch, the Setup Assistant and
  installing `container`, a first look round, running a first app from Suggestions, its page and logs,
  stopping and deleting it, downloading an image, and checking for updates. If you only have half an
  hour, do this.
- **The deeper path, optional:** short sections on the rest of Flotilla, such as the search box,
  lists, the Tasks panel, forms, groups, Suggestions, security findings, files, machines, health
  checks, Greta, accessibility, and two Macs. Each section says what its words mean. Do whichever
  interest you.

Along the core path there are a few short **first impressions** boxes: was it clear what to do next,
was anything confusing? Write a sentence or two, or leave them empty. They go into your summary at
the end. We read these as closely as the failures.

The [release notes](https://github.com/melonfleet/flotilla/releases/tag/v1.5.0-beta.5) list the known
limits. A known limit doesn't need a report unless it's worse than described.

## Reporting

**From the test page.** Press **Fail** on a step and GitHub's New issue page opens in a new tab, with
the step, what should have happened, your Flotilla and macOS versions, and whether this is your first
time using Flotilla already filled in. Add what actually happened and press Create. The page can't file
anything by itself: you submit every report with your own GitHub account. When you're done, **Send
summary** opens one more issue with your totals, the steps that failed and your first impressions.

**Without the page.** Open a [beta test report](https://github.com/melonfleet/flotilla/issues/new?template=beta-test.yml)
and fill it in, or open a plain issue if the form doesn't fit. Anything is better than nothing.
Something that confused you counts, even if nothing broke.

### What to include

- **What you did, what you expected, and what happened.** The exact wording of an error helps most.
- **Your Flotilla version and build**, from Settings ▸ About, for example
  `Version 1.5.0-beta.5 (612) · Tested with container 1.5.0`.
- **Your macOS version** (Apple menu ▸ About This Mac) and, if it might matter, your Mac model.
- **Whether this is your first time using Flotilla.**
- **A screenshot or short screen recording**, if you can.
- **A support bundle**, for anything that isn't obvious from a screenshot. In Flotilla choose
  **Help ▸ Create Support Bundle…**. It lists every file it would include and lets you read each one
  before you save. Nothing is uploaded. Save it, compress the folder in Finder (right-click ▸
  Compress), and drag the `.zip` into your report.

### What not to include

Reports on GitHub are **public**. Don't put any of these in the text, a screenshot or an attachment:

- passwords, registry credentials, API tokens or keys, private SSH keys, certificates;
- environment variables that hold secrets (check the Run form and `container inspect` output);
- personal data: your name, email, home folder path, other people's data, internal hostnames or IP
  addresses you'd rather keep private.

The support bundle redacts home-folder paths and account names and refuses to build if it finds
something it can't redact, but you are the last check. Read it before you attach it. If a report
can't be made without something private, say so in the issue and leave it out; we'll find another
way.

## Joining the tester group

Kamal can invite you by GitHub username to the melonfleet **beta-testers** team. That is how new
betas are announced. Tell him your username (see Contact below) and accept the invitation GitHub
emails you.

## If you used an earlier beta

Skip this section if this is your first time with Flotilla.

**Updating from beta 4.** You don't need to download anything. In beta 4, set the update channel in
Settings ▸ Updates to **Pre-release**, then choose **Flotilla ▸ Check for Updates…**. Beta 5 installs
and relaunches; your settings, groups and paired Macs are kept. Approve the Flotilla Helper if macOS
asks. If you manage several Macs, update the admin Mac first: it then updates its hosts itself, one at
a time, each when it is idle. The test page has a short optional section for this, at the end.

**Going back to beta 4.** Your containers, images, volumes and machines belong to Apple's `container`
and are not affected either way.

1. Quit Flotilla.
2. Download `Flotilla-1.5.0.0-beta.4.dmg` from the
   [beta 4 release](https://github.com/melonfleet/flotilla/releases/tag/v1.5.0.0-beta.4).
3. Drag Flotilla from the disk image to Applications and choose **Replace**. Use the disk image
   rather than the package to go back: the package is meant for upgrades.
4. Open Flotilla. When it offers beta 5 again, choose **Skip This Version**, or set the update
   channel in Settings ▸ Updates back to Stable.

Your settings, groups, tags and paired Macs stay. A few things beta 5 added, such as the SSH user name
you set for a host, are not known to beta 4 and may need setting again. Keep other Macs you manage on
the same beta as the admin Mac where you can: a Mac on beta 4 can't use the newer health-check and
restart-policy actions with a beta 5 Mac, in either direction. The Flotilla Helper restarts by itself
with the version inside the app you installed; if the status bar shows it as out of date, use
**Restart** in its menu. If you went back because of a bug, please report it, and say that you went
back.

## Contact

Bugs and questions about the beta go in [GitHub issues](https://github.com/melonfleet/flotilla/issues).
For anything that shouldn't be public, write to hello@melonfleet.dev.
