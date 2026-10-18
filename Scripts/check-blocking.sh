#!/usr/bin/env bash
#
# A blocking `container` call must run under `Blocking.run`, never directly in a `Task`.
#
# Flotilla stopped quitting (18 October). A sample of the hung app showed all 16 cooperative threads
# parked in `RemoteHost.run`'s semaphore, each from a `Task.detached { cli.versions() … }`:
# `Task.detached` still runs on Swift's cooperative pool, which has one thread per core and never
# grows, so every blocking call held a thread for its whole timeout, and with three hosts unreachable
# the pool ran dry. Nothing that needed it ran again, the quit included. A green suite cannot see
# this — the scripted hosts answer at once — and it looks exactly like correct code, which is why
# ~110 sites had it.
#
# Fails when a `Task.detached { … }` or `Task { … }` body in Sources/Flotilla calls a blocking
# `ContainerCLI` method outside a `Blocking.run { … }` inside it. The blocking methods are read from
# ContainerCLI.swift — every synchronous `throws` method that does not return a `CommandStream` (a
# stream returns at once) — so a new CLI call is covered without editing this list. Two names that
# are not on `ContainerCLI` are added by hand: `Preflight.run()` and `RemoteHost.run(_:timeout:)`,
# both of which wait on the CLI.
#
# Comments and string contents are blanked before scanning (interpolations are kept, as they run);
# `Task<Void, Never> { … }` and `Task<…>.detached { … }` count as tasks; and `await` in front of a
# blocking call does not excuse it — only `Blocking.run` does, or an async wrapper of the same name on
# `model`, `self` or `PrivilegedHelper` (see below). Kyle found the first four gaps (18 October);
# each is a negative control in Scripts/check-blocking-controls/, run before every scan, and the
# script fails if any of them stops being caught or if `shielded.swift` starts being caught.
# `Scripts/check-blocking.sh <file>…` scans just those files.
#
# Out of scope, because a lexical check cannot see it: a blocking call hidden behind an async
# wrapper — an `async` function that calls the CLI directly rather than under `Blocking.run`, or a
# helper with a name of its own. The call inside the wrapper is only flagged if the wrapper's own
# body is a `Task { … }`.
set -uo pipefail
cd "$(dirname "$0")/.."

python3 -I - "$@" <<'PY'
import pathlib, re, sys

cli = pathlib.Path('Sources/FlotillaCore/ContainerCLI.swift').read_text()
blocking = set()
for m in re.finditer(r'\bfunc\s+(\w+)\b', cli):
    sig = ' '.join(cli[m.start():cli.find('{', m.end())].split())
    if 'throws' in sig and 'async' not in sig and not sig.rstrip().endswith('CommandStream'):
        blocking.add(m.group(1))
# Plumbing, not called from the app: `execute`, `attempting`, `succeeding`, `streaming`.
blocking -= {'execute', 'attempting', 'succeeding', 'streaming'}
blocking |= {'run'}   # Preflight.run(), ContainerHost.run, RemoteHost.run(_:timeout:)
if len(blocking) < 40:
    print(f"✗ check-blocking found only {len(blocking)} blocking CLI methods — the parse is broken")
    sys.exit(1)

def strip(text):
    """Comments and string contents blanked, newlines kept, so offsets still give line numbers.

    Interpolations stay code: `"\(cli.stop(id))"` runs the call. Block comments nest, as Swift's do,
    and raw strings (`#"…"#`, `#"…\#(x)…"#`) close and interpolate with their own number of `#`."""
    out = []

    def blank(s):
        out.append(re.sub(r'[^\n]', ' ', s))

    def code(i, in_interpolation):
        depth = 0
        while i < len(text):
            if text.startswith('//', i):
                j = text.find('\n', i); j = len(text) if j < 0 else j
                blank(text[i:j]); i = j
            elif text.startswith('/*', i):
                j, nest = i + 2, 1
                while j < len(text) and nest:
                    if text.startswith('/*', j): nest += 1; j += 2
                    elif text.startswith('*/', j): nest -= 1; j += 2
                    else: j += 1
                blank(text[i:j]); i = j
            elif (m := re.match(r'#*"', text[i:i + 64])):
                i = string(i, len(m.group()) - 1)
            elif in_interpolation and text[i] == '(':
                depth += 1; out.append('('); i += 1
            elif in_interpolation and text[i] == ')':
                if depth == 0: return i
                depth -= 1; out.append(')'); i += 1
            else:
                out.append(text[i]); i += 1
        return i

    def string(i, hashes):
        pounds = '#' * hashes
        triple = text.startswith('"""', i + hashes)
        quote = '"""' if triple else '"'
        close, interpolate, escape = quote + pounds, '\\' + pounds + '(', '\\' + pounds
        opening = hashes + len(quote)
        blank(text[i:i + opening]); i += opening
        while i < len(text):
            if text.startswith(close, i):
                blank(close); return i + len(close)
            if not triple and text[i] == '\n':
                return i                      # unterminated: let the line end it
            if text.startswith(interpolate, i):
                blank(escape); out.append('('); i += len(interpolate)
                i = code(i, True)
                if i < len(text): out.append(')'); i += 1
            elif text.startswith(escape, i):
                blank(text[i:i + len(escape) + 1]); i += len(escape) + 1
            else:
                blank(text[i]); i += 1
        return i

    code(0, False)
    return ''.join(out)

def closure(text, brace):
    depth = 0
    for k in range(brace, len(text)):
        if text[k] == '{': depth += 1
        elif text[k] == '}':
            depth -= 1
            if depth == 0: return k + 1
    return len(text)

# `Task {`, `Task { @MainActor in`, `Task(priority: …) {`, `Task.detached {`, `Task.detached(operation: {`,
# and the explicitly typed `Task<Void, Never> {`, `Task<Void, Never>.detached {` (one level of nested
# generics, so `Task<Result<Int, Error>, Never>` too).
generic = r'(?:\s*<[^{}<>]*(?:<[^{}<>]*>[^{}<>]*)*>)?'
opener = re.compile(r'\bTask' + generic + r'(?:\s*\.\s*detached' + generic + r')?\s*(?:\([^{)]*\)?\s*)?\{')
shielded = re.compile(r'\bBlocking\.run\s*\(?\s*\{')
call = re.compile(r'(?:\bawait\s+([\w.]+))?\.(' + '|'.join(sorted(blocking)) + r')\s*\(')

# `await` makes nothing asynchronous: `await cli.stop(id)` compiles and still blocks, so an awaited
# call is flagged like a bare one. The one exception is an async wrapper of the same name on the
# app's own types — `await model.removeImage(…)` is `AppModel.removeImage(_:) async`, which does its
# CLI work under `Blocking.run` — and it is narrow on purpose: the receiver must be exactly one of
# these, and the name must be declared `async` in Sources/Flotilla. `await model.cli.stop(` is not.
wrapper_owners = {'model', 'self', 'PrivilegedHelper'}
wrappers = set()
for p in pathlib.Path('Sources/Flotilla').rglob('*.swift'):
    app = strip(p.read_text())
    for m in re.finditer(r'\bfunc\s+(\w+)\b', app):
        sig = ' '.join(app[m.start():app.find('{', m.end())].split())
        if re.search(r'\)\s*async\b', sig):
            wrappers.add(m.group(1))

def scan(paths):
    bad = set()
    for p in paths:
        text = strip(p.read_text())
        for m in opener.finditer(text):
            start = m.end() - 1
            end = closure(text, start)
            body = list(text[start:end])
            for b in shielded.finditer(text, start, end):
                s = b.end() - 1
                e = min(closure(text, s), end)
                body[s - start:e - start] = re.sub(r'[^\n]', ' ', text[s:e])
            body = ''.join(body)
            for c in call.finditer(body):
                if c.group(1) in wrapper_owners and c.group(2) in wrappers:
                    continue
                line = text.count('\n', 0, start + c.start()) + 1
                bad.add((str(p), line, c.group(2)))
    return bad

def report(bad):
    print("✗ blocking CLI calls inside a Task, on Swift's cooperative pool:")
    for path, line, name in sorted(bad):
        print(f"    {path}:{line}  .{name}(")
    print("  Wrap the blocking part in `await Blocking.run { … }` (FlotillaCore/Blocking.swift).")

# Files named on the command line: scan just those (how the controls are tried by hand).
if len(sys.argv) > 1:
    bad = scan([pathlib.Path(a) for a in sys.argv[1:]])
    if bad: report(bad); sys.exit(1)
    print("  blocking calls OK"); sys.exit(0)

# The controls first, every run: each `*.swift` there but `shielded.swift` hides a blocking call in a
# way an earlier version of this script missed, and must be caught; `shielded.swift` must not be.
controls = sorted(pathlib.Path('Scripts/check-blocking-controls').glob('*.swift'))
broken = [c.name for c in controls if (c.name == 'shielded.swift') == bool(scan([c]))]
if len(controls) < 5 or broken:
    print(f"✗ check-blocking's controls no longer behave ({', '.join(broken) or 'controls missing'}) — the check is broken")
    sys.exit(1)

bad = scan(sorted(pathlib.Path('Sources/Flotilla').rglob('*.swift')))
if bad:
    report(bad)
    sys.exit(1)
print(f"  blocking calls OK ({len(blocking)} CLI methods checked, {len(controls)} controls)")
PY
