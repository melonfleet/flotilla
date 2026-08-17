# Allowlist audit against `container` 1.0.0

> **Currency note — 17 August 2026.** This audit was written against a **35-entry** table.
> `Allowlist.commands` now holds **46**: the nine `machine` leaves, `copy`, and `build` have been
> added since. Those eleven are **not covered below** — they were reviewed separately, and the
> findings that came out of that work are recorded in
> [`reviews/KYLE-2026-08-09.md`](reviews/KYLE-2026-08-09.md) and in the addendum to
> [`MACHINES-SPEC.md`](MACHINES-SPEC.md), not here.
>
> Of the four defects listed below, all four have been fixed; the paragraph under each row says
> so. What has **not** changed is the conclusion that matters: 22 plugin-backed specs still have
> no captured help, so the table is still not trustworthy as the complete Phase 2 wire boundary.
> Re-running this audit against the current 46 entries is the work that would change that, and it
> has not been done.
>
> Kept as written rather than rewritten in place, because an audit is a record of what was
> examined on a date. Editing its body to match today's code would destroy the only thing it is
> for.

## Scope and result

This audit compares all 35 entries in `Allowlist.commands` with the captured help from `container` CLI 1.0.0, build `ee848e3`. The capture, not the repository's notes or external documentation, is the authority. [Capture version and provenance, lines 1–7](../reference/cli-help/container-1.0.0-help.txt#L1-L7)

I found **four defects that the capture proves**. None is a wrong flag spelling or wrong boolean/value declaration among the core commands whose detailed help was captured. The most serious defect is `start` accepting up to 32 operands even though the CLI accepts exactly one.

This is not a complete clean bill of health. The capture establishes that every allowlisted path exists, but it does **not** provide detailed help for 22 plugin-backed `CommandSpec`s; those help calls failed with `Plugin … not found`. It also has no dedicated sections for `stats` or `system version`. Consequently, the table is not yet trustworthy as a security boundary in its entirety.

Severity means:

- **High:** the allowlist admits an argv shape the CLI says is invalid, especially on a mutating command.
- **Medium:** the allowlist rejects a documented CLI capability or its `ValueShape` disagrees with the displayed CLI grammar.

## Defects

| Severity | `CommandSpec` | Defect | Authoritative evidence |
|---|---|---|---|
| **High** | `start` | `operands.max` is 32, but the CLI grammar has one required singular `<container-id>`. The allowlist therefore accepts and canonicalises `container start a b`, which is outside the captured grammar. Set `max` to 1. | The usage is `container start … <container-id>` and the argument is singular. [Capture, lines 236–246](../reference/cli-help/container-1.0.0-help.txt#L236-L246) |
| **High** | `run --publish` | `.portMapping` accepts a one-part bare port, but the captured grammar requires at least `host-port:container-port`, with only the host IP optional. This is a looser shape than the CLI and lets invalid input cross the wire boundary. Remove the one-part case. | `--publish` is ` [host-ip:]host-port:container-port[/protocol]`. [Capture, lines 111–112](../reference/cli-help/container-1.0.0-help.txt#L111-L112) |
| **Medium** | `run --memory` | `.memorySize` rejects the documented `T` and `P` suffixes. It also accepts suffix forms not named by the capture (`B`, `KB`, `MB`, `GB`); whether the CLI silently accepts those extra forms is **unverified**, so only the missing `T`/`P` capability is counted as proven. | The CLI explicitly permits an optional `K`, `M`, `G`, `T`, or `P` suffix. [Capture, lines 82–84](../reference/cli-help/container-1.0.0-help.txt#L82-L84) |
| **Medium** | `run --network` | `.identifier` accepts only the network name, rejecting the documented `,mac=…` and `,mtu=…` modifiers. This is a too-narrow `ValueShape`; introduce a reviewed network-attachment shape rather than widening `.identifier` globally. | The displayed format is `<name>[,mac=XX:XX:XX:XX:XX:XX][,mtu=VALUE]`. [Capture, lines 105–107](../reference/cli-help/container-1.0.0-help.txt#L105-L107) |

No defect is counted merely because Flotilla imposes a stricter resource limit. In particular, the CLI's plural/ellipsis operands do not state a maximum, while the allowlist's 32-operand cap is a defensible wire-boundary limit. The exception is `start`, whose captured grammar is explicitly singular. [Plural `inspect`, lines 317–323](../reference/cli-help/container-1.0.0-help.txt#L317-L323) [Singular `start`, lines 236–246](../reference/cli-help/container-1.0.0-help.txt#L236-L246)

## Omissions worth adding

These are CLI capabilities absent from the table that appear useful without defeating default deny. They are recommendations, not counted as defects unless already listed above.

| Priority | Omission | Judgement | Authoritative evidence |
|---|---|---|---|
| High | `run --read-only` | **Add.** It is a security-hardening switch and takes no value. | The flag mounts the container root filesystem read-only. [Capture, line 118](../reference/cli-help/container-1.0.0-help.txt#L118) |
| High | `run --label` / `-l` | **Add.** Labels are creation-time metadata and fit the existing `.keyValue` shape; make it repeatable after verifying repeat semantics. | The CLI declares `-l, --label <label>` with `key=value`. [Capture, line 102](../reference/cli-help/container-1.0.0-help.txt#L102) |
| Medium | `run --init` | **Add.** It is a value-less reliability option that forwards signals and reaps child processes. | The capture documents the boolean and its behavior. [Capture, lines 98–100](../reference/cli-help/container-1.0.0-help.txt#L98-L100) |
| Medium | `run --rosetta` | **Add when cross-architecture execution is in scope.** It is a value-less creation choice and is not recoverable after the container is launched. | The capture documents `--rosetta` as enabling Rosetta. [Capture, line 120](../reference/cli-help/container-1.0.0-help.txt#L120) |
| Medium | `run --shm-size` and `--tmpfs` | **Add after defining narrow shapes.** Both are useful resource/filesystem controls; `--shm-size` can reuse a corrected size grammar, while `--tmpfs` needs a new container-path shape. | The capture documents a size value and a path value. [Capture, lines 124–125](../reference/cli-help/container-1.0.0-help.txt#L124-L125) |
| Low | `run --no-dns` and the `--dns*` family | **Defer until custom DNS is a product requirement.** They are legitimate creation-time networking controls, but require reviewed IP/domain/option shapes rather than permissive strings. | The CLI exposes `--dns`, `--dns-domain`, `--dns-option`, `--dns-search`, and boolean `--no-dns`. [Capture, lines 93–96 and 108](../reference/cli-help/container-1.0.0-help.txt#L93-L108) |
| Low | `run --user`/`--uid`/`--gid`, `--workdir`, `--entrypoint`, and `--ulimit` | **Defer, then add only with dedicated shapes.** They are real execution controls, but their grammars are materially different and should not be forced through `.identifier` or `.commandToken`. | The capture gives the user format and declares values for all five controls. [Capture, lines 72–79](../reference/cli-help/container-1.0.0-help.txt#L72-L79) |

The following omissions should remain deliberate:

- `exec` should remain limited to the exact `ps -o pid,comm,args` policy. The CLI accepts an arbitrary command plus interactive, TTY, environment, identity, workdir, limits, and detach controls; exposing those would turn the remote grammar into general process execution. [Capture, lines 350–375](../reference/cli-help/container-1.0.0-help.txt#L350-L375)
- `start --attach` and `--interactive`, and `logs --follow`, should remain out until streaming/input transport is in scope. [Capture, lines 239–246](../reference/cli-help/container-1.0.0-help.txt#L239-L246) [Capture, lines 334–344](../reference/cli-help/container-1.0.0-help.txt#L334-L344)
- `run --env-file`, `--cidfile`, `--kernel`, `--publish-socket`, and `--ssh` cross host filesystem, kernel, socket, or credential boundaries and should remain excluded absent separate authorization policy. [Capture, lines 70–71, 91, 101, 116–117, and 123](../reference/cli-help/container-1.0.0-help.txt#L70-L123)
- `run --cap-add`, `--cap-drop`, `--runtime`, and `--virtualization` expand privilege or select trusted runtime machinery and should remain excluded. [Capture, lines 89–90, 121–122, and 126–127](../reference/cli-help/container-1.0.0-help.txt#L89-L127)
- `run --mount` should remain out until it has an authorization-aware shape; the existing `--volume` path is already bounded by `MountPolicy`. The CLI's alternate mount grammar is substantially broader. [Capture, lines 103–104](../reference/cli-help/container-1.0.0-help.txt#L103-L104)
- Bare-key `--env KEY` inheritance should remain rejected even though the CLI supports it: a remote caller should not be able to copy an unspecified host environment value into a container. `KEY=VALUE` remains supported. [Capture, lines 68–69](../reference/cli-help/container-1.0.0-help.txt#L68-L69)
- `--arch` and `--os` are redundant with the already allowlisted `--platform`, which the CLI says takes precedence. [Capture, lines 87–88, 109–115](../reference/cli-help/container-1.0.0-help.txt#L87-L115)
- `--remove` need not be added because the allowlist already emits the valid canonical alias `--rm`. [Capture, line 119](../reference/cli-help/container-1.0.0-help.txt#L119)
- `--scheme`, `--progress`, and `--max-concurrent-downloads` are transport/progress tuning rather than currently necessary container semantics; omission is reasonable. [Capture, lines 130–141](../reference/cli-help/container-1.0.0-help.txt#L130-L141)
- Global `--debug`, `--version`, and `--help` should remain outside every leaf spec. They are CLI control/output options, not Flotilla operations. [Capture, lines 12–17](../reference/cli-help/container-1.0.0-help.txt#L12-L17)

`build`, registry operations, machine operations, and image save/load remain out of Phase 1 by brief. The capture confirms those command families exist, but this audit does not recommend implementing them. [Top-level families, lines 38–55](../reference/cli-help/container-1.0.0-help.txt#L38-L55) [Image save/load, lines 473–483](../reference/cli-help/container-1.0.0-help.txt#L473-L483)

## What is correct

### Paths and aliases

Every allowlisted core path exists: `run`, `start`, `stop`, `kill`, `delete`/`rm`, `list`/`ls`, `inspect`, `logs`, `exec`, `stats`, and `prune`. The capture explicitly lists those paths and aliases. [Capture, lines 20–35](../reference/cli-help/container-1.0.0-help.txt#L20-L35)

Every allowlisted image, volume, network, and system leaf also appears in its parent command's subcommand list, including `rm` aliases and `system version`. Thus path spelling is verified even where leaf grammar is not. [Image leaves, lines 463–485](../reference/cli-help/container-1.0.0-help.txt#L463-L485) [Volume leaves, lines 604–621](../reference/cli-help/container-1.0.0-help.txt#L604-L621) [Network leaves, lines 688–705](../reference/cli-help/container-1.0.0-help.txt#L688-L705) [System leaves, lines 772–793](../reference/cli-help/container-1.0.0-help.txt#L772-L793)

### Core detailed grammar

- `list`/`ls` has the correctly spelled and valued `-a`/`--all`, `--format <format>`, and `-q`/`--quiet` flags. The four `.outputFormat` values—`json`, `table`, `yaml`, `toml`—exactly match the capture. [Capture, lines 302–311](../reference/cli-help/container-1.0.0-help.txt#L302-L311)
- `inspect` correctly requires one or more operands and has no allowlisted command-specific flags. [Capture, lines 317–326](../reference/cli-help/container-1.0.0-help.txt#L317-L326)
- The bounded `logs` subset has the correct singular operand, boolean `--boot`, and short-only valued `-n`. Deliberately omitting `--follow` does not make the declared subset wrong. [Capture, lines 331–345](../reference/cli-help/container-1.0.0-help.txt#L331-L345)
- `stop` has correct spellings, short aliases, value-ness, plural operands, and the `--all` zero-operand waiver. [Capture, lines 252–264](../reference/cli-help/container-1.0.0-help.txt#L252-L264)
- `kill` correctly has `--all`/`-a` and valued `--signal`/`-s`, no `--time`, plural operands, and the `--all` waiver. [Capture, lines 270–280](../reference/cli-help/container-1.0.0-help.txt#L270-L280)
- `delete`/`rm` correctly has `--all`/`-a`, `--force`/`-f`, plural operands, and the `--all` waiver. [Capture, lines 286–296](../reference/cli-help/container-1.0.0-help.txt#L286-L296)
- Container `prune` correctly has no allowlisted operands or command-specific flags and is mutating. [Capture, lines 380–386](../reference/cli-help/container-1.0.0-help.txt#L380-L386)
- For `run`, all declared flag spellings and boolean/value distinctions are present in the capture: `-d`/`--detach`, `--rm`, `--name`, `-e`/`--env`, `-p`/`--publish`, `-v`/`--volume`, `-c`/`--cpus`, `-m`/`--memory`, `--network`, and `--platform`. The image operand followed by process arguments also matches. The four `ValueShape` issues above are separate from spelling and value-ness. [Capture, lines 61–65, 68, 82–84, 92, 105–128](../reference/cli-help/container-1.0.0-help.txt#L61-L128)
- The exact `exec` policy is a valid strict subset of the CLI's required `<container-id> <arguments> ...` grammar. It is intentionally not a general representation of everything `exec` can do. [Capture, lines 350–375](../reference/cli-help/container-1.0.0-help.txt#L350-L375)

### `mutates`

The `mutates` classifications agree with the captured command descriptions at the persistent-resource level: list/inspect/log/status/version/df operations report state, while run/start/stop/kill/delete/prune/pull/tag/create/delete/prune operations create, change, or remove state. For example, the core capture describes `prune` as removing stopped containers and `list` as listing containers. [Capture, lines 302–305 and 380–383](../reference/cli-help/container-1.0.0-help.txt#L302-L383) The plugin parent help similarly describes image tag as creating a reference, volume/network prune as removing resources, and system status/version/df as reporting state. [Image leaves, lines 473–483](../reference/cli-help/container-1.0.0-help.txt#L473-L483) [Volume leaves, lines 614–619](../reference/cli-help/container-1.0.0-help.txt#L614-L619) [Network leaves, lines 698–703](../reference/cli-help/container-1.0.0-help.txt#L698-L703) [System leaves, lines 782–791](../reference/cli-help/container-1.0.0-help.txt#L782-L791)

The help text cannot prove retry safety. In particular, allowlisted `exec … ps …` starts a process even though it has no intended persistent mutation; whether `mutates: false` is the desired retry policy is **unverified**. The capture only establishes that `exec` runs a new command. [Capture, lines 350–357](../reference/cli-help/container-1.0.0-help.txt#L350-L357)

## Unverified

### Plugin-backed leaf grammar

The capture proves parent-level existence but does not settle any flag, short/long spelling, canonical spelling, value-ness, repeatability, operand bound, or `ValueShape` for these 22 specs:

- `image list`, `image inspect`, `image pull`, `image delete`, `image rm`, `image prune`, `image tag`
- `volume list`, `volume inspect`, `volume create`, `volume delete`, `volume rm`, `volume prune`
- `network list`, `network inspect`, `network create`, `network delete`, `network rm`, `network prune`
- `system status`, `system version`, `system df`

This is because every captured plugin leaf invocation returned `Plugin … not found` instead of help; `system version` was not invoked at all. Representative failures are the image failure [capture, lines 487–498](../reference/cli-help/container-1.0.0-help.txt#L487-L498), volume failure [capture, lines 623–634](../reference/cli-help/container-1.0.0-help.txt#L623-L634), network failure [capture, lines 707–718](../reference/cli-help/container-1.0.0-help.txt#L707-L718), and system failure [capture, lines 821–832](../reference/cli-help/container-1.0.0-help.txt#L821-L832). This means the capture does **not** independently verify the already-corrected short-only `volume create -s`, or `network create --subnet-v6` and `--plugin`; project notes cannot substitute for the designated authority.

To settle this, recapture 1.0.0 on a live installation where system services are running and all plugins resolve, and include `system version`. Each leaf section must contain its own `USAGE`, arguments, and options rather than an error.

### Missing detailed sections and under-specified value domains

`stats` exists at the top level, but its `--format`, `--no-stream`, and operand grammar are **unverified** because there is no `container stats` section in the capture. [The only captured `stats` evidence is the top-level listing, line 33](../reference/cli-help/container-1.0.0-help.txt#L33) A new `container stats --help` capture would settle it.

Even detailed help leaves some accepted domains unspecified:

- `logs -n` says “number of lines” but supplies no numeric range, so `.count`'s `1...1024` restriction is not verifiable from help. [Capture, lines 342–344](../reference/cli-help/container-1.0.0-help.txt#L342-L344)
- `stop --time` says seconds but gives no accepted range, and `stop`/`kill --signal` gives no complete signal grammar. `.durationSeconds` and `.signal` therefore remain unverified. [Capture, lines 261–264](../reference/cli-help/container-1.0.0-help.txt#L261-L264) [Capture, lines 279–280](../reference/cli-help/container-1.0.0-help.txt#L279-L280)
- `run --cpus`, `--platform`, `--volume`, the protocol part of `--publish`, and the image reference operand do not fully specify their parser domains. The corresponding shapes may be intentionally narrower, but the capture cannot prove exact agreement. [Capture, lines 61–64, 82, 111–115, and 128](../reference/cli-help/container-1.0.0-help.txt#L61-L128)
- The capture does not say which flags are repeatable. The allowlist's repeat counts and caps are therefore policy limits, not verified CLI limits. The displayed `run` option declarations contain no repeatability metadata. [Capture, lines 67–141](../reference/cli-help/container-1.0.0-help.txt#L67-L141)

These domains require either parser-level 1.0.0 documentation generated from the same binary or a recorded accept/reject probe matrix against that exact build. Until then, any shape that is narrower is a policy choice; any potentially looser case should be treated as unverified rather than assumed safe.

## Security-boundary judgement

**Not trustworthy as the complete Phase 2 wire boundary today.** The verified core subset is mostly faithful and default-deny limits the blast radius, but two proven shapes admit grammar outside the captured CLI (`start` arity and bare-port `--publish`), two documented creation choices are unreachable through incorrect shapes, and 22 of 35 entries lack authoritative leaf-level verification. The capture must be repaired and the four proven defects fixed with tests before the whole table can reasonably receive a security-boundary clean bill of health.
