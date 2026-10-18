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
set -uo pipefail
cd "$(dirname "$0")/.."

python3 -I - <<'PY'
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
    """Comments and string literals blanked, newlines kept, so offsets still give line numbers."""
    out, i, n = [], 0, len(text)
    while i < n:
        if text.startswith('//', i):
            j = text.find('\n', i); j = n if j < 0 else j
            out.append(' ' * (j - i)); i = j
        elif text.startswith('"""', i):
            j = text.find('"""', i + 3); j = n if j < 0 else j + 3
            out.append(re.sub(r'[^\n]', ' ', text[i:j])); i = j
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] not in '"\n':
                j += 2 if text[j] == '\\' else 1
            out.append(' ' * (j + 1 - i)); i = j + 1
        else:
            out.append(text[i]); i += 1
    return ''.join(out)

def closure(text, brace):
    depth = 0
    for k in range(brace, len(text)):
        if text[k] == '{': depth += 1
        elif text[k] == '}':
            depth -= 1
            if depth == 0: return k + 1
    return len(text)

# `Task {`, `Task { @MainActor in`, `Task(priority: …) {`, `Task.detached {`, `Task.detached(operation: {`.
opener = re.compile(r'\bTask(?:\.detached)?\s*(?:\([^{)]*\)?\s*)?\{')
shielded = re.compile(r'\bBlocking\.run\s*\(?\s*\{')
awaited = re.compile(r'\bawait\s+[\w.]*$')
call = re.compile(r'\.(' + '|'.join(sorted(blocking)) + r')\s*\(')

bad = set()
for p in sorted(pathlib.Path('Sources/Flotilla').rglob('*.swift')):
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
            # `await model.removeImage(…)` is AppModel's async wrapper of the same name, not the CLI.
            if awaited.search(body, 0, c.start()):
                continue
            line = text.count('\n', 0, start + c.start()) + 1
            bad.add((str(p), line, c.group(1)))

if bad:
    print("✗ blocking CLI calls inside a Task, on Swift's cooperative pool:")
    for path, line, name in sorted(bad):
        print(f"    {path}:{line}  .{name}(")
    print("  Wrap the blocking part in `await Blocking.run { … }` (FlotillaCore/Blocking.swift).")
    sys.exit(1)
print(f"  blocking calls OK ({len(blocking)} CLI methods checked)")
PY
