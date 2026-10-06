#!/usr/bin/env bash
# Build, inspect or tear down the "Acme Shop" demo: a populated Flotilla for website screenshots.
#
#   Scripts/demo-scenario.sh up [--no-cluster]   create everything (about 160 MB of images, plus
#                                                2.4 GB for the cluster's node image)
#   Scripts/demo-scenario.sh status              list what the demo has created
#   Scripts/demo-scenario.sh down [--images]     remove it all, and restore your own groups, tags
#                                                and registries; --images also deletes the images
#
# WHAT IT TOUCHES, AND WHAT IT NEVER DOES
#
# - Every container, volume and network it makes carries the label `demo=flotilla`, and `down`
#   deletes **only** labelled ones. Machines and clusters take no labels, so those are removed by
#   the exact names below. Nothing of yours is in either set.
# - Flotilla's groups, tags and registry list live in its preferences. Before writing the demo's,
#   `up` saves yours (once, so a second `up` cannot overwrite the backup with demo data), and
#   `down` puts them back exactly. Flotilla reads preferences only at launch, so the script quits
#   it before writing and opens it again afterwards.
# - The Postgres password is generated here and kept in the state folder; it is a test value for
#   a container that listens on this Mac only.
#
# The plan the owner approved, 5 October: TODO.md, "Demo scenario for website screenshots".
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$ROOT/Scripts/demo"
STATE="$HOME/Library/Application Support/Flotilla Demo"
DOMAIN="dev.melonfleet.Flotilla"
LABEL="demo=flotilla"
PREF_KEYS=(containerGroups tagDefinitions tagAssignments registries)

MACHINES=(dev-box ci-runner)
CLUSTER="dev-cluster"
NETWORKS=(shop-net analytics-net docs-net)
VOLUMES=(shop-db-data shop-uploads analytics-data)
# The containers that are running in the demo; the rest are stopped on purpose.
RUNNING=(storefront-web storefront-api storefront-db storefront-cache docs-site build-runner)

CADDY="docker.io/library/caddy:2-alpine"
PYTHON="docker.io/library/python:3.13-alpine"
POSTGRES="docker.io/library/postgres:17-alpine"
REDIS="docker.io/library/redis:7-alpine"
ALPINE="docker.io/library/alpine:3.22"
API_IMAGE="acme/storefront-api:1.0"

say() { printf '▸ %s\n' "$*"; }
quiet() { "$@" >/dev/null 2>&1; }

need_runtime() {
  command -v container >/dev/null || { echo "✗ no \`container\` on PATH" >&2; exit 1; }
  container system status >/dev/null 2>&1 || { echo "✗ the container service isn't running: container system start" >&2; exit 1; }
}

quit_flotilla() {
  if pgrep -xq Flotilla; then
    say "quitting Flotilla so its preferences can be written"
    osascript -e 'quit app "Flotilla"' >/dev/null 2>&1 || true
    for _ in $(seq 40); do pgrep -xq Flotilla || return 0; sleep 0.25; done
    echo "✗ Flotilla did not quit — close any open dialog in it and run this again" >&2
    exit 1
  fi
}

open_flotilla() {
  local app="$ROOT/build/Flotilla.app"
  if [ -d "$app" ]; then open "$app"; else open -a Flotilla 2>/dev/null || true; fi
}

# Whether the demo cluster exists. Matched as a whole word anywhere on a row: `k8s list` leaves its
# CLUSTER column blank, which shifts every field, so a column number would read the wrong one.
has_cluster() { container k8s list 2>/dev/null | awk 'NR>1' | grep -qw "$CLUSTER"; }

# A container that exists already is left as it is, so `up` can be run again after a partial run.
exists_container() { container inspect "$1" >/dev/null 2>&1; }

run_container() {   # name, `run` or `create`, then that command's own arguments
  local name="$1" verb="$2"; shift 2
  if exists_container "$name"; then say "  $name exists"; return; fi
  # The name and label straight after the verb: anything after the image is the command to run.
  container "$verb" --name "$name" --label "$LABEL" "$@" >/dev/null
  say "  $name"
}

# MARK: up

up() {
  local with_cluster=1
  [ "${1:-}" = "--no-cluster" ] && with_cluster=0
  need_runtime
  mkdir -p "$STATE"
  chmod 700 "$STATE"
  # Not `tr </dev/urandom | head`: `head` closes the pipe early, and under `pipefail` that is a
  # failure (exit 141) before anything has happened.
  [ -s "$STATE/postgres-password" ] || (umask 077; python3 -c 'import secrets; print(secrets.token_urlsafe(18))' > "$STATE/postgres-password")

  say "pulling images"
  for image in "$CADDY" "$PYTHON" "$POSTGRES" "$REDIS" "$ALPINE"; do
    quiet container image inspect "$image" || container image pull "$image" >/dev/null
    say "  $image"
  done

  say "building $API_IMAGE"
  if ! quiet container image inspect "$API_IMAGE"; then
    container build -t "$API_IMAGE" "$ASSETS/api" >/dev/null
    # The build leaves its BuildKit container running, which would sit in every screenshot of the
    # Containers list. It is the runtime's own and comes back on the next build.
    quiet container builder stop || true
    quiet container builder delete || true
  fi
  say "  $API_IMAGE"

  say "networks and volumes"
  quiet container network inspect shop-net || container network create --label "$LABEL" --subnet 192.168.70.0/24 shop-net >/dev/null
  quiet container network inspect analytics-net || container network create --label "$LABEL" --subnet 192.168.71.0/24 analytics-net >/dev/null
  quiet container network inspect docs-net || container network create --label "$LABEL" --subnet 192.168.72.0/24 docs-net >/dev/null
  for volume in "${VOLUMES[@]}"; do
    quiet container volume inspect "$volume" || container volume create --label "$LABEL" -s 1G "$volume" >/dev/null
  done
  say "  ${NETWORKS[*]} · ${VOLUMES[*]}"

  say "containers"
  # storefront: the running group.
  run_container storefront-web run -d --network shop-net -p 127.0.0.1:8080:80 \
    -v "$ASSETS/site:/usr/share/caddy:ro" "$CADDY"
  # 8090, not 8000: the fleet's good-night sweep frees :8000 for its console, which stopped
  # this container the first night (5 October).
  run_container storefront-api run -d --network shop-net -p 127.0.0.1:8090:8000 \
    -v shop-uploads:/uploads "$API_IMAGE"
  # PGDATA in a subfolder: a new volume is not empty (it has lost+found), and Postgres refuses to
  # initialise a data directory that is.
  run_container storefront-db run -d --network shop-net \
    -e POSTGRES_PASSWORD="$(cat "$STATE/postgres-password")" -e POSTGRES_DB=shop \
    -e PGDATA=/var/lib/postgresql/data/pgdata \
    -v shop-db-data:/var/lib/postgresql/data "$POSTGRES"
  run_container storefront-cache run -d --network shop-net "$REDIS"
  # docs: partly running.
  # docs has its own network like the other two groups. On the default network its published port
  # stopped answering after the service had been restarted and other networks recreated (an
  # upstream networking fault seen 6 October; see research/CONTAINER-UPGRADE-1.5.0.md).
  run_container docs-site run -d --network docs-net -p 127.0.0.1:8081:80 -v "$ASSETS/docs:/usr/share/caddy:ro" "$CADDY"
  run_container docs-search create --network docs-net "$PYTHON" python -m http.server 7700
  # analytics: stopped.
  run_container analytics-worker create --network analytics-net -v analytics-data:/data \
    "$PYTHON" python -c "import time; time.sleep(10**9)"
  run_container analytics-queue create --network analytics-net "$REDIS"
  # Standalone.
  run_container build-runner run -d "$ALPINE" sleep 1000000000
  run_container scratch-shell create "$ALPINE" sleep 1000000000
  # Running again after a restart of the container service, which stops everything: `up` puts the
  # demo back the way it is meant to look, not only creates what is missing.
  for name in "${RUNNING[@]}"; do
    if [ "$(container inspect "$name" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["status"]["state"])' 2>/dev/null)" != "running" ]; then
      quiet container start "$name" && say "  $name started"
    fi
  done

  say "machines"
  for m in "${MACHINES[@]}"; do
    quiet container machine inspect "$m" || container machine create --name "$m" --cpus 2 --memory 2G "$ALPINE" >/dev/null
  done
  # `machine create` boots a machine, and on container 1.5 the first `machine run` after it fails
  # and *stops* the machine (measured 6 October) — which is what left dev-box stopped on 5 October,
  # not the order. So: stop ci-runner, and boot dev-box with one retry, as Flotilla's Start does.
  quiet container machine stop ci-runner || true
  container machine run --name dev-box -- /bin/true >/dev/null 2>&1 \
    || container machine run --name dev-box -- /bin/true >/dev/null 2>&1 || true
  say "  ${MACHINES[*]}"

  if [ "$with_cluster" -eq 1 ]; then
    if has_cluster && container k8s list 2>/dev/null | grep -w "$CLUSTER" | grep -qw stopped; then
      # 1.5 has no `k8s start`: a stopped cluster is recreated, as Flotilla's own Recreate does.
      say "cluster $CLUSTER is stopped; recreating it"
      container k8s delete --name "$CLUSTER" >/dev/null
      container k8s create --name "$CLUSTER" --cpus 2 --memory 4G >/dev/null
    elif has_cluster; then
      say "cluster $CLUSTER exists"
    else
      say "cluster $CLUSTER (the node image is 2.4 GB the first time; this takes a few minutes)"
      container k8s create --name "$CLUSTER" --cpus 2 --memory 4G >/dev/null
    fi
  fi

  quit_flotilla
  write_prefs
  open_flotilla
  say "waiting for Flotilla, then making some activity for the feed"
  sleep 8
  activity
  say "done — Scripts/demo-scenario.sh down removes it all"
}

# Groups, tags and the registry list. Yours are saved first and restored by `down`.
write_prefs() {
  if [ ! -f "$STATE/prefs-backup.plist" ]; then
    say "saving your groups, tags and registries"
    python3 - "$DOMAIN" "$STATE/prefs-backup.plist" "${PREF_KEYS[@]}" <<'PY'
import plistlib, subprocess, sys, os
domain, out, keys = sys.argv[1], sys.argv[2], sys.argv[3:]
raw = subprocess.run(["defaults", "export", domain, "-"], capture_output=True).stdout
prefs = plistlib.loads(raw) if raw else {}
backup = {k: prefs[k] for k in keys if k in prefs}
backup["__absent__"] = [k for k in keys if k not in prefs]
with open(out, "wb") as f: plistlib.dump(backup, f)
os.chmod(out, 0o600)
PY
  fi
  # The database password where Flotilla keeps group passwords: the login Keychain, keyed by
  # group id and secret name (`KeychainSecrets`). `down` deletes it.
  security add-generic-password -U -s dev.melonfleet.Flotilla.group-secret \
    -a demo.storefront/db-password -l "Flotilla: storefront — db-password" \
    -w "$(cat "$STATE/postgres-password")" >/dev/null
  say "writing the demo's groups, tags and registries"
  python3 - "$DOMAIN" "$STATE/prefs-backup.plist" "$ASSETS" <<'PY'
import plistlib, subprocess, sys
domain, backup_path, assets = sys.argv[1], sys.argv[2], sys.argv[3]
backup = plistlib.load(open(backup_path, "rb"))

def member(mid, name, image, **extra):
    row = {"id": mid, "name": name, "image": image}
    row.update({k: v for k, v in extra.items() if v})
    return row

groups = [
    {"id": "demo.storefront", "name": "storefront", "network": "shop-net", "members": [
        member("demo.m.web", "storefront-web", "docker.io/library/caddy:2-alpine",
               ports=["127.0.0.1:8080:80"], volumes=[f"{assets}/site:/usr/share/caddy:ro"]),
        member("demo.m.api", "storefront-api", "acme/storefront-api:1.0",
               ports=["127.0.0.1:8090:8000"], volumes=["shop-uploads:/uploads"]),
        # The same settings the container was run with, so Start can rebuild it (6 October:
        # the record had none, and a rebuilt database would have had no password). The password
        # is a Keychain secret, written below, never a value in the preferences.
        member("demo.m.db", "storefront-db", "docker.io/library/postgres:17-alpine",
               env=["POSTGRES_DB=shop", "PGDATA=/var/lib/postgresql/data/pgdata"],
               secretEnv=[{"name": "POSTGRES_PASSWORD", "secret": "db-password"}],
               volumes=["shop-db-data:/var/lib/postgresql/data"], readyPort=5432),
        member("demo.m.cache", "storefront-cache", "docker.io/library/redis:7-alpine"),
    ]},
    {"id": "demo.docs", "name": "docs", "network": "docs-net", "members": [
        member("demo.m.docs-site", "docs-site", "docker.io/library/caddy:2-alpine",
               ports=["127.0.0.1:8081:80"], volumes=[f"{assets}/docs:/usr/share/caddy:ro"]),
        member("demo.m.docs-search", "docs-search", "docker.io/library/python:3.13-alpine",
               command=["python", "-m", "http.server", "7700"]),
    ]},
    {"id": "demo.analytics", "name": "analytics", "network": "analytics-net", "members": [
        member("demo.m.worker", "analytics-worker", "docker.io/library/python:3.13-alpine",
               volumes=["analytics-data:/data"]),
        member("demo.m.queue", "analytics-queue", "docker.io/library/redis:7-alpine"),
    ]},
]
# The user's own groups stay, after the demo's.
groups += [g for g in backup.get("containerGroups", []) if not str(g.get("id", "")).startswith("demo.")]

tags = list(backup.get("tagDefinitions", []))
have = {t["id"] for t in tags}
for tid, name, color in [("demo.frontend", "Frontend", "blue"), ("demo.backend", "Backend", "purple"),
                         ("demo.data", "Data", "green")]:
    if tid not in have: tags.append({"id": tid, "name": name, "color": color})

P, S, NA = "starter.production", "starter.staging", "starter.needs-attention"
F, B, D, DEV, EXP = "demo.frontend", "demo.backend", "demo.data", "starter.development", "starter.experiment"
assignments = dict(backup.get("tagAssignments", {}))
assignments.update({
    "group/demo.storefront": [P], "group/demo.docs": [S], "group/demo.analytics": [EXP],
    "container/storefront-web": [F], "container/storefront-api": [B], "container/storefront-db": [D],
    "container/storefront-cache": [B], "container/docs-site": [F], "container/docs-search": [NA],
    "container/build-runner": [DEV],
    "volume/shop-db-data": [D, P], "volume/analytics-data": [D],
    "network/shop-net": [P],
    "machine/dev-box": [DEV], "machine/ci-runner": [S],
    "registry/ghcr.io": [DEV],
})

registries = list(backup.get("registries", []))
if not any(r.get("host") == "quay.io" for r in registries):
    registries.append({"host": "quay.io", "name": "Quay", "kind": "quay", "scheme": "https",
                       "signIn": "optional", "summary": "Red Hat's public registry."})

for key, value in [("containerGroups", groups), ("tagDefinitions", tags),
                   ("tagAssignments", assignments), ("registries", registries)]:
    xml = plistlib.dumps(value).decode()
    subprocess.run(["defaults", "write", domain, key, xml], check=True)
PY
}

# Some feed entries, made while Flotilla is running to see them.
activity() {
  quiet container stop build-runner || true
  sleep 3
  quiet container start build-runner || true
  sleep 3
  quiet container stop docs-site || true
  sleep 3
  quiet container start docs-site || true
}

# MARK: status

labelled() {   # list | inspect json → names of resources carrying the demo label
  python3 -c '
import json, sys
label_key, label_value = sys.argv[1].split("=")
for item in json.load(sys.stdin):
    cfg = item.get("configuration", item)
    labels = cfg.get("labels") or item.get("labels") or {}
    if labels.get(label_key) == label_value:
        print(cfg.get("id") or item.get("name") or item.get("id"))
' "$LABEL"
}

status() {
  need_runtime
  echo "containers: $(container ls -a --format json | labelled | tr '\n' ' ')"
  echo "volumes:    $(container volume ls --format json | labelled | tr '\n' ' ')"
  echo "networks:   $(container network ls --format json | labelled | tr '\n' ' ')"
  local machines=""
  for m in "${MACHINES[@]}"; do container machine inspect "$m" >/dev/null 2>&1 && machines+="$m "; done
  echo "machines:   $machines"
  echo "cluster:    $(has_cluster && echo "$CLUSTER" || true)"
  echo "prefs:      $([ -f "$STATE/prefs-backup.plist" ] && echo "demo written; yours saved in $STATE" || echo "yours")"
}

# MARK: down

down() {
  need_runtime
  quit_flotilla
  say "containers"
  for name in $(container ls -a --format json | labelled); do
    container delete --force "$name" >/dev/null && say "  $name"
  done
  say "machines and cluster"
  for m in "${MACHINES[@]}"; do
    if container machine inspect "$m" >/dev/null 2>&1; then
      quiet container machine stop "$m" || true
      container machine delete "$m" >/dev/null && say "  $m"
    fi
  done
  if has_cluster; then
    container k8s delete --name "$CLUSTER" >/dev/null && say "  $CLUSTER"
  fi
  say "volumes and networks"
  for name in $(container volume ls --format json | labelled); do
    container volume delete "$name" >/dev/null && say "  $name"
  done
  for name in $(container network ls --format json | labelled); do
    container network delete "$name" >/dev/null && say "  $name"
  done

  if [ -f "$STATE/prefs-backup.plist" ]; then
    say "restoring your groups, tags and registries"
    python3 - "$DOMAIN" "$STATE/prefs-backup.plist" <<'PY'
import plistlib, subprocess, sys
domain, path = sys.argv[1], sys.argv[2]
backup = plistlib.load(open(path, "rb"))
for key in backup.pop("__absent__", []):
    subprocess.run(["defaults", "delete", domain, key], capture_output=True)
for key, value in backup.items():
    subprocess.run(["defaults", "write", domain, key, plistlib.dumps(value).decode()], check=True)
PY
    rm -f "$STATE/prefs-backup.plist"
  fi

  if [ "${1:-}" = "--images" ]; then
    say "images"
    for image in "$API_IMAGE" "$CADDY" "$PYTHON" "$POSTGRES" "$REDIS"; do
      quiet container image delete "$image" && say "  $image" || true
    done
  fi
  security delete-generic-password -s dev.melonfleet.Flotilla.group-secret \
    -a demo.storefront/db-password >/dev/null 2>&1 || true
  rm -f "$STATE/postgres-password"
  rmdir "$STATE" 2>/dev/null || true
  say "done"
}

case "${1:-}" in
  up) shift; up "$@" ;;
  down) shift; down "$@" ;;
  status) status ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
