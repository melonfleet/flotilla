# Machine package checks — 19 October 2026

Checks run only from the machine Overview's Check for Updates button. Results and last-attempt
state stay in memory per machine. Flotilla never installs a package. Alpine refreshes its own
indexes from its configured mirrors; DNF uses the machine's configured repositories and cache.

The argv passed to `container` (each bullet is a separate invocation):

- Alpine: `["machine", "run", "--name", ID, "apk", "update"]`, then
  `["machine", "run", "--name", ID, "apk", "version", "-l", "<"]`.
- AlmaLinux: `["machine", "run", "--name", ID, "dnf", "-q", "check-update"]`, then
  `["machine", "run", "--name", ID, "rpm", "-qa", "--queryformat", "%{NAME}.%{ARCH}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\n"]`.
  The format argument contains literal backslash-t and backslash-n, which RPM expands.
  RPM supplies installed versions absent from DNF's available-update rows, keyed by name and
  architecture, including epochs and multiple installed versions where applicable.

Before these commands, and again before each individual invocation, Flotilla runs
`["machine", "inspect", ID]` and requires a running machine with the same recognized distribution.
All commands, including inspections, share a 120-second budget. The CLI offers no atomic
check-and-run: another client stopping the machine between inspection and `machine run` could
cause `machine run` to boot it. Flotilla's own controls share the machine busy guard.

The Allowlist selects separate exact specs only with `ExecPolicy.interactiveShell` (the app's
production policy). They require `--name`, permit no other flags or operands, and remain local
only. Existing boot and interactive-shell specs retain their grammars. Callers put `--` before
the fixed command for validation; canonical argv strips it, as for other command execution.
There is no shell. Package names or parsed text never become argv.

DNF exit 100 is accepted only for the check-update invocation; all other package commands require
zero. See [DNF's command reference](https://dnf.readthedocs.io/en/stable/command_ref.html#check-update-command).
Failures, truncation, malformed rows and exceeded limits produce an error instead of a partial
count or an 'Up to date' claim. Parsing limits: 2 MB per output, 20,000 lines, 1,024 bytes per line,
256 bytes per token, 1,000 updates. Only printable ASCII and tabs are accepted, and display uses
verbatim text. RPM versions joined for one package have an additional 1,024-byte ceiling.

## Capture and validation gap

The installed `container` binary is present, but `container machine list --format json` fails with
'Operation not permitted' in this mirror. No APK, DNF or RPM package-output fixtures were captured
or written. Both parsers remain untested by design, pending real captures from running Alpine and
AlmaLinux machines. The output formats and the complete live UI flow have not been verified here.

Tests cover exact argv acceptance, adjacent command rejection, default/remote policy denial,
preservation of boot and shell, the stopped-machine guard, refresh failure short-circuiting,
deadlines and DNF exit-100 handling. Guard tests reuse the existing captured
`Tests/FlotillaCoreTests/Fixtures/machine-inspect.json`, adapting only its state or image reference;
they stop before parsing any package-manager output.
