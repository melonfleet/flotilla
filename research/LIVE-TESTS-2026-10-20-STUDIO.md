# Live tests: Iris's suggestion candidates on the Studio

Run on **20 October 2026**, on one Mac (the Studio).

- `container` CLI **1.5.0** (build: release, commit `d265d66`)
- macOS **27.0.1** (build `26A434`), Apple silicon, `linux/arm64` images

Source: `research/SUGGESTIONS-EXPANSION-IRIS.md` (19 October 2026), and the `flotilla-library` entries at VERSION `2026.10.18.1` (commit `a8b0c8d`).

**Method.** Every container, volume and network used the `flt-test-` prefix. Host ports were moved to free 19xxx ports (`127.0.0.1:19xxx:<container port>`); the container ports, env, mounts and commands are exactly the recipe's. Each `secret(KEY)` was a fresh random value from `openssl rand -hex`, never a fixed string. "Replace" means `container stop` + `container rm`, then a new `container run` with the same arguments on the same volume. Where the recipe has a schema-2 `volumeOwner`, or a test showed one was needed, the fresh volume was prepared with the app's own helper: `docker.io/library/busybox@sha256:bdf57e52…f82e` (the `Allowlist.volumeSetupBusyboxDigest` pin) running the exact `VolumeSetupStore.helperScript`, so the owner is set on the mount root only, with no recursion. Digests are the image index digest from `container image inspect`, plus the `linux/arm64` manifest that actually ran.

---

## Failures and fixes needed (read first)

| Candidate | What failed | Evidence | Verdict |
|---|---|---|---|
| **Mailpit, library recipe today** (`/data` volume, no `MP_DATABASE`) | Mail is lost when the container is replaced. Nothing is ever written to `/data`. | before: `total 1 ['flt-old-1']`; `/data` holds only `lost+found`; after replace: `total after replace 0 []` | **Fix**: use Iris's recipe (passes, below) |
| **NATS, library recipe today** (`-m 8222 -js`, `/data` volume) | JetStream is stored in `/tmp/nats/jetstream`, outside the volume. Stream and messages are lost on replace. | `jsz store_dir: /tmp/nats/jetstream`; before: `messages: 3`; after: `{'code': 404, 'err_code': 10059, 'description': 'stream not found'}` | **Fix**: use Iris's recipe (passes, below) |
| **Redis snapshots volume** (`redis:8.10.2`, `/data`, `redis-server --save 60 1`) | Unlike Valkey, the image does **not** fix `/data` ownership. It runs as `999:999` and can't write to the root-owned volume, so snapshots fail and the key is lost. `--appendonly yes` won't even start. | `Uid: 999 999 999 999`; `/data` is `0 0 drwxr-xr-x`; on stop: `# Error trying to save the DB, can't exit.`; after replace: `GET flt:key -> '$-1'`. AOF control: `Can't open or create append-only dir appendonlydir: Permission denied` | **Fix**: needs `volumeOwner 999:999`. With it: `DB saved on disk`, and after replace `GET flt:key -> 'redis-persisted'`. **The library's current `redis` entry has the same volume and no `volumeOwner`, so it has the same defect** (see "Needs a human decision") |
| **Ghost content volume** (`ghost:6.71.0`, `/var/lib/ghost/content`) | With only the image and mount, Ghost 6 in its default production mode won't start, because it needs MySQL. The volume itself is fine. | first run: `ERROR connect ECONNREFUSED 127.0.0.1:3306`, container `stopped` | **Fix**: the contract must name the database dependency. With `mysql:8.4.11` wired through the gateway, it passes (below) |
| PostgreSQL 17 volume **without** the `PGDATA` companion (control) | `initdb` refuses the mount root because of `lost+found`. This confirms Iris's `PGDATA=/var/lib/postgresql/data/pgdata` companion is required, not optional. | `initdb: error: directory "/var/lib/postgresql/data" exists but is not empty` / `It contains a lost+found directory` | Keep the companion env (the recipe as proposed passes) |
| Ownership controls: Grafana, Prometheus and pgAdmin on a **raw** fresh volume | All three need their recorded owner. pgAdmin is the worst case: its state stays `running` while the app is broken. | Grafana: `GF_PATHS_DATA='/var/lib/grafana' is not writable`, stopped. Prometheus: `open /prometheus/queries.active: permission denied`, stopped. pgAdmin: `Failed to create the directory /var/lib/pgadmin/sessions: [Errno 13] Permission denied`, state `running` | Keep `volumeOwner` (472:0, 65534:65534, 5050:0). With it, all three pass |

---

## Step 1: Mailpit and NATS, today vs. Iris's fix

| Candidate | Recipe values | Image digest | Write | Replace and recover | Verdict |
|---|---|---|---|---|---|
| Mailpit, **library today** | `ghcr.io/axllent/mailpit:v1.31.5`; ports 8025, 1025; env `MP_MAX_MESSAGES=500`; vol `1G` at `/data` | index `sha256:94f6b70c1436defae6799d9ac7ff0eeff9540465b842026d5cdb018f1c0234ea`; arm64 `sha256:1c1bda89291dff96ea8aa5a760ae644413c3526302fbf25f996a2987eaf0db78` | PASS: SMTP to 1025, then `total 1 ['flt-old-1']` | **FAIL**: `total after replace 0 []` | **fix** |
| Mailpit, **Iris** | as above, plus `MP_DATABASE=/data/mailpit.db` | same | PASS: `total 1 ['flt-new-1']`; `/data` has `mailpit.db`, `mailpit.db-shm`, `mailpit.db-wal` | PASS: `after replace: total 1 ['flt-new-1']` | **ship** |
| NATS, **library today** | `docker.io/library/nats:2.15.0`; ports 4222, 8222; command `["-m","8222","-js"]`; vol `5G` at `/data` | index `sha256:cd3fcd4ecdda44e3a66728a5334af0a959bc3979b32810e033d1c547241cd0f4`; arm64 `sha256:c5385888c04605faecc3379bdaa0cf9862cab97e40d328e0f1d9a505e5c12634` | PASS: file stream `FLTTEST` created, 3 acks (`seq` 1 to 3), `messages: 3`, but `store_dir: /tmp/nats/jetstream` | **FAIL**: `stream not found` (404, 10059) | **fix** |
| NATS, **Iris** | command `["-js","-sd","/data","-m","8222"]`; the rest as above | same | PASS: `store_dir: /data/jetstream`; 3 acks; `messages: 3, storage file` | PASS: `messages: 3, first_seq 1, last_seq 3`; `seq 1: message 1`; log: `Store Directory: "/data/jetstream"` … `Starting restore for stream '$G > FLTTEST'` | **ship** |

Ownership: neither image needs a `volumeOwner`. Both run as root, and the files on the volume are `root root`.

---

## Step 2: app candidates

| Candidate | Recipe values (Iris) | Image digest | Checks (pass/fail, trimmed output) | Verdict |
|---|---|---|---|---|
| **Adminer** | `docker.io/library/adminer:6.1.2`; `127.0.0.1:8080:8080`; no env, command or volume | index `sha256:49a7d30e71de97fb18933ffe7d46cc2b343c49fd7a63a7791c8be2548eb65115`; arm64 `sha256:9ad6244d96b308f877bee41b4543a4de984084093cfe3252d7a7194218253e11` | Real login through the form (with CSRF token) to `postgres:18.6` and `mariadb:13.0.2`. The databases published on the gateway, `192.168.64.1:19432` and `192.168.64.1:19306`, as in DECISIONS Q20. PASS pgsql via gateway: `title='Schema: public - 192.168.64.1:19432 - Adminer' logged_in=True`. PASS pgsql via container IP. PASS MySQL/MariaDB via gateway: `title='Database: app - 192.168.64.1:19306 - Adminer' logged_in=True`. PASS MariaDB via container IP. Negative control, wrong password: HTTP 403 | **ship** |
| **Gotenberg** | `docker.io/gotenberg/gotenberg:8.38.1`; `127.0.0.1:3000:3000`; nothing else | index `sha256:aa552cc115db488e0f0bcb07446aac13071ad51505b642c84bb894500907b42b`; arm64 `sha256:5a76359017b3a4110adcfec7abd2222ace17be2b137dad8c5b0b35cea763baa9` | PASS `/health`: chromium `up`, libreoffice `up`. PASS HTML→PDF: `HTTP 200 application/pdf 8183 bytes`, `%PDF-1.4`, 1 page. PASS DOCX→PDF (LibreOffice route): `HTTP 200 application/pdf 10895 bytes`, `%PDF-1.7`, 1 page | **ship**. Note: the same default host port, 3000, as Grafana |
| **Qdrant** | `docker.io/qdrant/qdrant:v1.19.2`; 6333, 6334; `QDRANT__SERVICE__API_KEY=secret`; vol `10G` at `/qdrant/storage` | index `sha256:b7b0444c4c351c970b98e90a6f89c2ee4287c65b44e52b4cb503fa5b2aa927ad`; arm64 `sha256:9eb80ba088703193c124db5e50a59f2028439c8bbc62fa1918625995116b50d0` | PASS auth: no key → `401`. PASS create collection (size 4, Cosine): `"result":true`. PASS upsert of 2 points: `completed`. PASS query: top hit `id 1, score 1.0, payload {"n":"one"}`. gRPC 6334: TCP connect only, `succeeded` (no gRPC call was made). PASS replace: `status green points 2`, same top hit | **ship** |
| **Meilisearch** | `docker.io/getmeili/meilisearch:v1.55.0`; 7700; `MEILI_MASTER_KEY=secret`; vol `10G` at `/meili_data` | index `sha256:ff546679970126f8822e15d1b6a06bfbff1f2ce2e43f810cfb5258012f92de5c`; arm64 `sha256:3369dcba3e34085d880adf63a1eea2acac828554fe3a82e0a380c7f6af923149` | PASS auth: no key → `401`. PASS index 2 docs; typo-tolerant search `harbor` → `['Flotilla harbour']`. PASS replace: `numberOfDocuments 2`, same search result | **ship** |
| **Valkey** | `docker.io/valkey/valkey:9.1.2`; 6379; command `valkey-server --save 60 1`; vol `2G` at `/data` | index `sha256:418652cfb58ef879d4978c33553735d7147016032d5aefaa14c828e611eb9dfd`; arm64 `sha256:5a6ac3cceea0d4cebe48911dfa5f393f49feea86a2c55c5ac6b0ba733a1713b6` | PASS fresh volume: the entrypoint gives `/data` to `999` itself. The server runs as `uid=999(valkey) gid=999(valkey)`, and `dump.rdb` is `999 999`. PASS replace after explicit `SAVE`: `Done loading RDB, keys loaded: 1`. PASS replace without `SAVE`, graceful stop only: `Saving the final RDB snapshot before exiting` / `DB saved on disk`, then `GET → 'no-manual-save'` | **ship**, no `volumeOwner` needed |
| **Grafana** | `docker.io/grafana/grafana:13.2.3`; 3000; `GF_SECURITY_ADMIN_USER=admin`, `GF_SECURITY_ADMIN_PASSWORD=secret`; vol `5G` at `/var/lib/grafana`, owner `472:0` | index `sha256:b28bae15e219c998fb0e0424ed724930cc61b1f61fb404d47c862f9a23f9e572`; arm64 `sha256:c474a2845f8cd51bf09c3f24e036225912fdb21cd0c87ac89527c395585bfa22` | Raw volume: FAIL, as expected (see failures). With the helper at 472:0: PASS `/api/health` `database ok, 13.2.3`. PASS wrong password → `401`. PASS dashboard saved: `status success, uid flt-test-dash, version 1`. Process `uid=472(grafana) gid=0(root)`. PASS replace: `title: Flotilla persistence check version: 1` | **ship** (owner 472:0 confirmed) |

Mailpit and NATS, the other two of Iris's eight, are in step 1.

---

## Step 3: volume candidates paired with an image

"Owner needed" is what the volume root must be before first start, on Apple's fresh root-owned ext4 volume (`0:0`, `755`, containing `lost+found`).

| Volume candidate | Image and digest | Owner needed | Write, then replace and recover | Verdict |
|---|---|---|---|---|
| `postgres18-data` 10G at `/var/lib/postgresql` | `postgres:18.6`, index `sha256:74935e72241653ca55e0414067e6d8763aceb8a810eb51b452253ec3dcfc4336`, arm64 `sha256:a63b24165ea0eacced7585766d790ac08bbaefe10a1841f87783a4505d29a69c` | none (the entrypoint handles it); `PGDATA=/var/lib/postgresql/18/docker` | PASS: `insert` → after replace `pg18-persisted` | **ship** |
| `postgres17-data` 10G at `/var/lib/postgresql/data` + `PGDATA=/var/lib/postgresql/data/pgdata` | `postgres:17.11`, index `sha256:2d2b8998d31037bf721cfdf764d76ba74171b4fab3431b7f72c27c56ddbdf9e3`, arm64 `sha256:2d46d14f5a051d8c1e4f9d7c07dbeb877ae08150654d69ca32903ccbae4a5421` | none; `pgdata` becomes `999 0` | PASS: after replace `pg17-persisted`. Without `PGDATA`: FAIL (see failures) | **ship** with the companion env |
| `mysql-data` 10G at `/var/lib/mysql`: MySQL | `mysql:8.4.11`, index `sha256:0f51e63e537a1f176423fa03ef559aabe6fa4372a53160a44bc7e75da7d15364`, arm64 `sha256:4452d4257b94692c09df0f6011a3275744746001150f3cdbdc9278bacfa385bb` | none (files `999 999`) | PASS: after replace `mysql-persisted` | **ship** |
| `mysql-data` 10G at `/var/lib/mysql`: MariaDB | `mariadb:13.0.2`, index `sha256:0e4bb0f339feba125d1154fbacd36c16ec8518f52e44e1f82ecec7d6771caf39`, arm64 `sha256:945b885fa8b3c472afeb5f2c18b615823bce1683879e69a663307e9fc37e8340` | none (root `999 0`) | PASS: after replace `mariadb-persisted`. Each engine was tested on its own fresh volume; the volumes are not interchangeable | **ship** |
| `mongo-data` 10G at `/data/db` | `mongo:9.0.2`, index `sha256:f5c6240ae8fccc21cf75acc6462929b3394a7a5a7abd934b6b0e7ada5eb5fe95`, arm64 `sha256:a18a67668df9389cbfe49d81ca9bd20428fa6b82ce9ae0b79961dadf56281493` | none (root `999 0`) | PASS: `insertOne … true` → after replace `mongo-persisted` | **ship** |
| `redis-data` 2G at `/data` + `redis-server --save 60 1` | `redis:8.10.2`, index `sha256:2c2dff791878316e3b083188be0d578423b24813cdda5de0e80ea4f7b3e6bfd6`, arm64 `sha256:ec87069acc319552b908ba0709277d17a0fe768fcfbdd78b7271d77b4a1bd3ed` | **`999:999`** (the image does not chown) | Raw: **FAIL**. With the helper at 999:999: PASS, `GET → 'redis-persisted'` | **fix** (add `volumeOwner 999:999`) |
| `valkey-data` 2G at `/data` | `valkey:9.1.2` (digest above) | none (the entrypoint chowns to 999) | PASS (step 2) | **ship** |
| `grafana-data` 5G at `/var/lib/grafana` | `grafana:13.2.3` (digest above) | **`472:0`**, confirmed | Raw FAIL; owned PASS (step 2) | **ship** |
| `prometheus-data` 10G at `/prometheus` + recipe command | `prom/prometheus:v3.15.0`, index `sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e`, arm64 `sha256:6b41f7a45cfbd1d259a78701ee5e14fc2ad9383c9aa5d0427345a18539bc3c91`; image `User: nobody` | **`65534:65534`**, confirmed | Raw: FAIL (`permission denied`). Owned: PASS. Self-scrape `count_over_time(up[60m]) = 5` before and immediately after replace. Log: `WAL segment loaded … segment=3` / `WAL replay completed` | **ship** |
| `pgadmin-data` 2G at `/var/lib/pgadmin` | `dpage/pgadmin4:9.18.0`, index `sha256:c332c5f6dfba995d9ebc4af261d93506d6876085d712eaaa3defc8dd1a3f26de`, arm64 `sha256:6373d89ab2767c52875aee1aafd3731781abb4a5774f5633f7d9d8762efde536`; image `User: 5050` | **`5050:0`**, confirmed | Raw: FAIL, silently (`running`, but `Permission denied`). Owned: PASS. `setup.py load-servers` → `Added … 1 Server(s)`; after replace, `dump-servers` → `['flt-test-server']` | **ship** |
| `qdrant-data` 10G at `/qdrant/storage` | `qdrant:v1.19.2` (digest above), image `User: 0:0` | none | PASS (step 2) | **ship** |
| `meilisearch-data` 10G at `/meili_data` | `meilisearch:v1.55.0` (digest above) | none (runs as root) | PASS (step 2) | **ship** |
| `mailpit-data` 1G at `/data` + `MP_DATABASE` | `mailpit:v1.31.5` (digest above) | none | PASS only with `MP_DATABASE` (step 1) | **ship** |
| `nats-data` 5G at `/data` + `-js -sd /data -m 8222` | `nats:2.15.0` (digest above) | none | PASS only with `-sd /data` (step 1) | **ship** |
| `wordpress-data` 5G at `/var/www/html` | `wordpress:7.1-php8.4-apache`, index `sha256:309307430abf80009378a63a79df73554a6449b700fac59a991b4959e6dda8ca`, arm64 `sha256:624d9f0376f937ef87fcc8e7b84e451de40167d027d025da3456c6b7004fb8e5` | none (the entrypoint populates the empty volume as `33 33`) | With `mariadb:13.0.2` via the gateway: install `200`. A file written as `33:33` in `wp-content/uploads`, then replace: PASS. File served `flt-upload`, `<title>FltTest</title>`, `wp-config.php` kept | **ship** |
| `ghost-content` 5G at `/var/lib/ghost/content` | `ghost:6.71.0`, index `sha256:00032f15726204565bf799ac272ee6fef588547cce50bedd38de3db55272c053`, arm64 `sha256:e36b9fd9c4c8b48d671d9a9532f62577dc9f439499bb96fbe4d181ad38fa2bc0` | none (the entrypoint populates as `1000`, root `1000 0`) | Alone: FAIL (needs MySQL). With `mysql:8.4.11` via the gateway (`database__client=mysql`, `database__connection__*`): PASS. Site API up, `casper` theme seeded; an image written as `1000:1000`, then replace → `image -> 200 image/gif` | **fix** (document the DB dependency) |

### Extra evidence for Job 3 (PostgreSQL major-version mismatch)

- `postgres:18.6` with a PG17-style mount at `/var/lib/postgresql/data`: **refuses to start**. `Error: in 18+, these Docker images are configured to store database data in a … there appears to be PostgreSQL data in: /var/lib/postgresql/data (unused mount/volume)`.
- `postgres:17.11` with the PG18 mount at `/var/lib/postgresql`: on Apple `container` it **did** persist, because `PGDATA=/var/lib/postgresql/data` lands inside the mount and there is no anonymous-volume behaviour. It is still the wrong contract: the volume holds a PG17 cluster under a PG18-labelled recipe, and on Docker-style runtimes the declared `VOLUME` would capture it instead.

---

## Not tested, or limits

- One Mac only. There is no second-Mac evidence for any row.
- Qdrant gRPC (6334): TCP connect only.
- Gotenberg: one HTML and one minimal DOCX conversion; other office formats were not tried.
- Adminer was tested standalone against separately started databases, not as Iris's `postgres-adminer` / `mariadb-adminer` stacks with `ADMINER_DEFAULT_SERVER`.
- Valkey's 60-second timed snapshot was not waited for. Persistence was proven via `SAVE` and via the shutdown snapshot.
- Host ports were moved to free 19xxx ports, so Iris's exact host-port defaults were not bound. Note her proposed Gotenberg and Grafana both default to `127.0.0.1:3000`.

## Needs a human decision

1. **Library `redis` entry (`entries/databases/redis.json`, tested 2026-10-13):** same image, mount and fresh-volume behaviour as the failing row above, and no `volumeOwner`. On this Studio it cannot save snapshots onto a fresh volume. It needs `volumeOwner {uid: 999, gid: 999}` and a re-test. This is outside Job 2's brief (Mailpit and NATS only), so it was left unchanged.
2. Ghost: either ship as a stack with MySQL, or keep the volume preset with a stated database requirement.
3. Gotenberg vs Grafana default host port collision (3000).

## State left on the Studio

All `flt-test-` containers and volumes were removed after the tests, and no networks were created. The pulled images were left in place (pulled, not tagged; the rules only cover removing `flt-test-` resources): mailpit, nats, adminer, gotenberg, qdrant, meilisearch, valkey, grafana, postgres 18.6 and 17.11, mariadb, mysql, mongo, redis, prometheus, pgadmin4, wordpress `7.1-php8.4-apache`, ghost, and busybox at the app's pinned digest. The existing `wordpress` and `ollama` containers and their volumes were not touched.
