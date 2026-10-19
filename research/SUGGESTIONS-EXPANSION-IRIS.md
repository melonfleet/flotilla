**Flotilla Suggestions expansion — research and design recommendation**

19 October 2026 · Target runtime: Apple `container` 1.5.0

Consolidate discovery into one Suggestions section with **Apps, Stacks, Volumes, Networks, Domains, Machines and Clusters**, plus an **Images** tab in a later increment. Add an **All** tab for searching the complete catalogue. Keep registry discovery in the existing Add Registry flow.

Move catalogue content into the signed library, with a bundled fallback. Keep command construction, validation, privilege handling and execution in the app. Expanding beyond apps and stacks requires a schema change: the current schema 2 only understands `container` and `stack` entries.

The following lists are a research backlog, not a declaration that every candidate is ready to ship. They contain eight candidates per area, fifteen for volumes, and eight optional image candidates. Some improve existing entries rather than add another product.

**Evidence and confidence**

This research inspected the repository’s decisions, suggestion implementations, machine specification, captured CLI help, and the separate library checkout. That library identifies itself as schema 2, version `2026.10.18.1`, with 35 app entries and six stack entries. Its signature was not independently reverified during this research. No containers, machines or clusters were started, and no repository files were changed.

The tables use these confidence labels:

- **Recorded:** the repository records a successful run of the relevant existing recipe. This is historical evidence, not a new test.
- **T–high:** upstream documentation supports the recipe; a live Flotilla test is required before shipping.
- **T–medium:** the proposal also has a compatibility, ownership or integration question to resolve.
- **Blocked:** an app capability or evidence gap must be addressed before testing and publication.

A recorded launch does not establish persistence, recovery or every supported connection mode. Changed images, arguments, mounts or ownership invalidate the corresponding test evidence.

**CLI and prefill conventions**

The version-labelled aggregate help capture is the authority for 1.5.0; some individual captures are older. The proposed fields map to these supported operations:

| Resource | Argument mapping |
|---|---|
| App | Image operand; `--name`; repeated `--env KEY=value`, `--publish ADDRESS:HOST_PORT:CONTAINER_PORT`, `--volume NAME:DESTINATION`; optional `--network NAME`. Application command arguments follow the image. |
| Volume | `container volume create -s SIZE NAME` |
| Network | `container network create [--internal] [--subnet CIDR] [--subnet-v6 PREFIX] NAME` |
| Machine | `container machine create --name NAME --cpus N --memory SIZE --home-mount ro\|rw\|none IMAGE` |
| Cluster | `container k8s create --name NAME --cpus N --memory SIZE --node-image REFERENCE [--rm]` |
| Image | `container image pull --platform linux/arm64 --scheme https REFERENCE` |

These are mappings for the existing forms, not commands to execute when a row is selected. Fields not listed are not overridden. Names are starting values; existing collision handling may append a numeric suffix. Port changes must appear in the review form.

For app recipes, published ports below bind to `127.0.0.1`. `secret(KEY)` means a newly generated secret using Flotilla’s existing secret handling, never that literal text or a shared catalogue password. Volume paths below are destinations **inside containers**.

There is one capture gap: the inspected help collection does not contain the DNS-create leaf. The existing wrapper and Apple’s versioned source support `container system dns create [--localhost IP] DOMAIN`, but this should be captured before publishing new DNS recipes. No unverified DNS flag is proposed. [Apple 1.5.0 DNS implementation](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/ContainerCommands/System/DNS/DNSCreate.swift)

**Apps: eight candidates**

For each named volume, create it with the specified size before mounting it. Empty command means preserve the image’s default command.

| Candidate and audience | Exact proposed prefill | Why this default; confidence |
|---|---|---|
| **Adminer** — developers inspecting SQL databases | Name `adminer`; image `docker.io/library/adminer:6.1.2`; publish `127.0.0.1:8080:8080`; no environment, command override or volume. | A useful standalone database browser without another stateful service. The image includes PostgreSQL and MySQL drivers. **T–high:** test login to both engines, including Flotilla’s gateway connection mode. [Image documentation](https://hub.docker.com/_/adminer) |
| **Gotenberg** — developers building document conversion features | Name `gotenberg`; image `docker.io/gotenberg/gotenberg:8.38.1`; publish `127.0.0.1:3000:3000`; no environment, command override or volume. | Adds a document-to-PDF API without inventing a persistent-data requirement. **T–high:** test actual HTML and office-document conversions, not just a listening port. [Installation](https://gotenberg.dev/docs/getting-started/installation), [published tags](https://hub.docker.com/r/gotenberg/gotenberg/tags) |
| **Qdrant** — developers experimenting with vector search | Name `qdrant`; image `docker.io/qdrant/qdrant:v1.19.2`; publish `127.0.0.1:6333:6333` and `127.0.0.1:6334:6334`; environment `QDRANT__SERVICE__API_KEY=secret(API_KEY)`; volume `qdrant-data`, `10G`, mounted at `/qdrant/storage`. | Includes both HTTP and gRPC access, explicit authentication and a persistent collection store. **T–medium:** verify volume permissions and collection survival after container replacement. Keep this a local-development recipe. [Quickstart](https://qdrant.tech/documentation/quickstart/), [authentication](https://qdrant.tech/documentation/security/), [tags](https://hub.docker.com/r/qdrant/qdrant/tags) |
| **Meilisearch** — developers adding application search | Name `meilisearch`; image `docker.io/getmeili/meilisearch:v1.55.0`; publish `127.0.0.1:7700:7700`; environment `MEILI_MASTER_KEY=secret(MASTER_KEY)`; volume `meilisearch-data`, `10G`, at `/meili_data`. | Gives the service an explicit key and persistent index storage. **T–medium:** verify the exact image’s ownership requirements and index recovery. [Docker deployment](https://www.meilisearch.com/docs/resources/self_hosting/getting_started/docker), [tags](https://hub.docker.com/r/getmeili/meilisearch/tags) |
| **Mailpit, persistent** — developers testing outgoing mail | Name `mailpit`; image `ghcr.io/axllent/mailpit:v1.31.5`; publish `127.0.0.1:8025:8025` and `127.0.0.1:1025:1025`; environment `MP_MAX_MESSAGES=500`, **`MP_DATABASE=/data/mailpit.db`**; volume `mailpit-data`, `1G`, at `/data`. | Improves the existing entry: mounting `/data` alone does not select Mailpit’s database file. Its default database is temporary. **T–high:** send a message, replace the container, and verify the message remains. [Runtime options](https://mailpit.axllent.org/docs/configuration/runtime-options/) |
| **NATS with persistent JetStream** — developers testing messaging | Name `nats`; image `docker.io/library/nats:2.15.0`; publish `127.0.0.1:4222:4222` and `127.0.0.1:8222:8222`; command arguments `["-js","-sd","/data","-m","8222"]`; volume `nats-data`, `5G`, at `/data`. | Improves the existing entry by explicitly placing JetStream data on the mounted volume. **T–high:** create a file-backed stream and verify retained messages after replacement. [Image documentation](https://hub.docker.com/_/nats), [versioned server options](https://raw.githubusercontent.com/nats-io/nats-server/v2.15.0/server/opts.go) |
| **Valkey, persistent** — developers needing a local cache or key-value store | Name `valkey`; image `docker.io/valkey/valkey:9.1.2`; publish `127.0.0.1:6379:6379`; command `["valkey-server","--save","60","1"]`; volume `valkey-data`, `2G`, at `/data`. | Retains the existing snapshot configuration while making its persistence contract testable. **T–medium:** verify the exact image’s UID/GID and fresh-volume behaviour; do not guess an owner. [Image documentation](https://hub.docker.com/r/valkey/valkey) |
| **Grafana, persistent** — developers exploring dashboards | Name `grafana`; image `docker.io/grafana/grafana:13.2.3`; publish `127.0.0.1:3000:3000`; environment `GF_SECURITY_ADMIN_USER=admin`, `GF_SECURITY_ADMIN_PASSWORD=secret(ADMIN_PASSWORD)`; volume `grafana-data`, `5G`, at `/var/lib/grafana`; schema-2 owner `472:0`. | A useful retained baseline for validating shared catalogue and ownership handling. The inspected library records this image and owner. **Recorded baseline; T–high for any changed recipe:** save a dashboard and verify replacement recovery. [Container configuration](https://grafana.com/docs/grafana/latest/setup-grafana/configure-docker/) |

The Mailpit and NATS changes deserve priority over adding more logos: they correct the relationship between the advertised volume and the application’s actual storage configuration.

**Stacks: eight candidates**

Use the existing stack planner and group model. A stack suggestion must remain an editable group with an explicit start order.

The following shorthand defines exact reusable service recipes:

| Component | Exact values |
|---|---|
| `PG(database)` | Image `docker.io/library/postgres:18.6`; environment `POSTGRES_DB=database`, `POSTGRES_USER=database`, `POSTGRES_PASSWORD=secret(DB_PASSWORD)`; data volume `10G` at `/var/lib/postgresql`; wired/ready port `5432`. [PostgreSQL image](https://hub.docker.com/_/postgres) |
| `Maria(database)` | Image `docker.io/library/mariadb:13.0.2`; environment `MARIADB_DATABASE=database`, `MARIADB_USER=database`, `MARIADB_PASSWORD=secret(DB_PASSWORD)`, `MARIADB_ROOT_PASSWORD=secret(ROOT_PASSWORD)`; data volume `10G` at `/var/lib/mysql`; wired/ready port `3306`. [MariaDB image](https://hub.docker.com/_/mariadb) |
| `MySQL(database)` | Image `docker.io/library/mysql:8.4.11`; environment `MYSQL_DATABASE=database`, `MYSQL_USER=database`, `MYSQL_PASSWORD=secret(DB_PASSWORD)`, `MYSQL_ROOT_PASSWORD=secret(ROOT_PASSWORD)`; data volume `10G` at `/var/lib/mysql`; wired/ready port `3306`. [MySQL image](https://hub.docker.com/_/mysql) |

For all eight:

- The proposed group name appears below. Container names are `<group>-<role>`, the new network is `<group>-net`, and volumes are `<group>-<role>-data`.
- Use a normal network, with `--internal` absent. Subnet selection belongs to the planner’s collision-checked allocation.
- `{{host:db}}` and `{{port:db}}` are existing typed planner substitutions. With container DNS they resolve to the service name and native port; without it, the planner uses its gateway publication route.
- Shared `secret(DB_PASSWORD)` references within one stack resolve to the same newly generated value. Different stacks receive different secrets.
- Start database services first and retain the existing readiness wait. That wait is not a continuing health monitor.
- Public UI ports below are loopback bindings. Database wiring must not become an unrestricted host publication.

| Candidate and audience | Exact proposed service prefill | Why this default; confidence |
|---|---|---|
| **PostgreSQL + Adminer** — SQL learning and application development | Group `postgres-adminer`; role `db` = `PG(app)`; role `adminer` = the Adminer app recipe, adding `ADMINER_DEFAULT_SERVER={{host:db}}:{{port:db}}`; UI `127.0.0.1:8080:8080`. | A database and browser with little extra state. **T–high:** test PostgreSQL login through both DNS and gateway wiring. [Adminer configuration](https://hub.docker.com/_/adminer) |
| **MariaDB + Adminer** — MySQL-compatible application development | Group `mariadb-adminer`; `db` = `Maria(app)`; `adminer` as above; UI `127.0.0.1:8080:8080`. | Reuses the same browser and form conventions across two SQL engines. **T–high:** test login, restart and data recovery. [Adminer configuration](https://hub.docker.com/_/adminer) |
| **WordPress + MariaDB** — theme, plugin and content development | Group `wordpress`; `db` = `Maria(wordpress)`; `site` image `docker.io/library/wordpress:7.1-php8.4-apache`; environment `WORDPRESS_DB_HOST={{host:db}}:{{port:db}}`, `WORDPRESS_DB_NAME=wordpress`, `WORDPRESS_DB_USER=wordpress`, `WORDPRESS_DB_PASSWORD=secret(DB_PASSWORD)`; site volume `5G` at `/var/www/html`; UI `127.0.0.1:8080:80`. | Preserve this useful compiled stack when consolidating catalogues. **T–medium:** the database pin differs from the compiled recipe; test installation, uploads and replacement recovery together. [WordPress image](https://hub.docker.com/_/wordpress) |
| **Ghost + MySQL** — publishing-site development | Group `ghost`; `db` = `MySQL(ghost)`; `site` image `docker.io/library/ghost:6.71.0`; environment `database__client=mysql`, `database__connection__host={{host:db}}`, `database__connection__port={{port:db}}`, `database__connection__user=ghost`, `database__connection__password=secret(DB_PASSWORD)`, `database__connection__database=ghost`, `url=http://127.0.0.1:2368`; volume `5G` at `/var/lib/ghost/content`; UI `127.0.0.1:2368:2368`. | A useful additional publishing stack. **Blocked, then T–medium:** bind `url` to the final reviewed host port; the current placeholder set cannot express that dependency. Also verify this MySQL version with this Ghost image. [Ghost image](https://hub.docker.com/_/ghost), [configuration](https://docs.ghost.org/config/) |
| **Gitea + PostgreSQL** — local Git-service evaluation | Group `gitea`; `db` = `PG(gitea)`; `web` image `ghcr.io/go-gitea/gitea:28.1.0`; environment `GITEA__database__DB_TYPE=postgres`, `GITEA__database__HOST={{host:db}}:{{port:db}}`, `GITEA__database__NAME=gitea`, `GITEA__database__USER=gitea`, `GITEA__database__PASSWD=secret(DB_PASSWORD)`; volume `10G` at `/data`; UI `127.0.0.1:3000:3000`. | Retain an existing library stack and its tested image reference. Browser setup remains part of first use. **Recorded baseline; T–high for changes:** verify repository creation and persistence, not just the setup page. [Gitea container configuration](https://docs.gitea.com/installation/install-with-docker/) |
| **Metabase + PostgreSQL** — local analytics evaluation | Group `metabase`; `db` = `PG(metabase)`; `web` image `docker.io/metabase/metabase:v0.64.1`; environment `MB_DB_TYPE=postgres`, `MB_DB_DBNAME=metabase`, `MB_DB_HOST={{host:db}}`, `MB_DB_PORT={{port:db}}`, `MB_DB_USER=metabase`, `MB_DB_PASS=secret(DB_PASSWORD)`; UI `127.0.0.1:3000:3000`; no application data volume. | Improve the existing stack by removing the misleading application-volume promise when PostgreSQL holds Metabase’s application database. **T–high:** verify saved configuration survives replacement. [Metabase deployment](https://www.metabase.com/docs/latest/installation-and-operation/running-metabase-on-docker) |
| **Prometheus + Grafana** — metrics exploration | Group `metrics`; `prometheus` image `docker.io/prom/prometheus:v3.15.0`; command `["--config.file=/etc/prometheus/prometheus.yml","--storage.tsdb.path=/prometheus","--web.enable-lifecycle"]`; volume `10G` at `/prometheus`, owner `65534:65534`; UI `127.0.0.1:9090:9090`; wired port `9090`. `grafana` uses the app recipe above with UI `127.0.0.1:3000:3000`. | Preserve another useful compiled stack. Show the resolved Prometheus datasource address in the detail/setup instructions; do not claim it is automatically provisioned. **T–high:** test datasource connection and both volumes. [Prometheus installation](https://prometheus.io/docs/prometheus/latest/installation/), [Grafana configuration](https://grafana.com/docs/grafana/latest/setup-grafana/configure-docker/) |
| **Application backend kit** — developers supplying their own application | Group `dev-backend`; `db` = `PG(app)`; `cache` = Valkey recipe above; `mail` = corrected Mailpit recipe above. Publish database `127.0.0.1:5432:5432`, cache `127.0.0.1:6379:6379`, mail UI `127.0.0.1:8025:8025`, SMTP `127.0.0.1:1025:1025`. | Gives a host-run application three common dependencies without inventing an application image. **T–medium:** verify coexistence of host access, group wiring, port reassignment and all persistence contracts. [Valkey image](https://hub.docker.com/r/valkey/valkey), [Mailpit options](https://mailpit.axllent.org/docs/configuration/runtime-options/) |

There is a migration trap: the fetched library currently replaces the built-in app/stack catalogue. Its six stacks do not include all five compiled stack recipes. Consolidation must reconcile stable IDs and explicitly preserve or retire those recipes; simply moving the existing fetched entries into tabs would lose useful suggestions.

**Volumes: fifteen candidates**

A volume suggestion creates an **empty named volume**. It does not install an image, set environment variables or attach itself to a container.

Every row below therefore has two parts:

1. Exact Volume-form values: name and size.
2. A version-specific mount contract shown in details and reused by app, stack and group-service forms.

The sizes are proposed development defaults, not vendor minimums. Apple’s volumes are sparse, so the size is a ceiling rather than an immediate allocation. [Apple volume documentation](https://raw.githubusercontent.com/apple/container/1.5.0/docs/volumes.md)

| Candidate and audience | Exact create values and image contract | Why this default; confidence |
|---|---|---|
| **PostgreSQL 18 data** — current PostgreSQL projects | Name `postgres18-data`; size `10G`; image `docker.io/library/postgres:18.6`; mount `/var/lib/postgresql`. | Separates the new layout from older PostgreSQL. **Recorded path; T–high** for the standalone handoff. [Image storage contract](https://hub.docker.com/_/postgres) |
| **PostgreSQL 17 data** — projects remaining on PostgreSQL 17 | `postgres17-data`; `10G`; `docker.io/library/postgres:17.11`; mount `/var/lib/postgresql/data`; companion environment `PGDATA=/var/lib/postgresql/data/pgdata`. | Explicit major-version choice prevents applying the PostgreSQL 18 mount to an older image. The child directory also needs fresh-volume validation. **T–high.** [Image storage contract](https://hub.docker.com/_/postgres) |
| **MySQL / MariaDB data** — relational application storage | `mysql-data`; `10G`; `docker.io/library/mysql:8.4.11` or `docker.io/library/mariadb:13.0.2`; mount `/var/lib/mysql`. | Retains a useful existing preset. Sharing a mount path does not make existing data interchangeable between engines. **T–high:** test each supported image separately. [MySQL](https://hub.docker.com/_/mysql), [MariaDB](https://hub.docker.com/_/mariadb) |
| **MongoDB data** — document-database development | `mongo-data`; `10G`; `docker.io/library/mongo:9.0.2`; mount `/data/db`. | Keeps the ordinary database case separate from specialised cluster roles. **Recorded path; T–high** for persistence. [MongoDB image](https://hub.docker.com/_/mongo) |
| **Redis snapshots** — persistent local key-value data | `redis-data`; `2G`; `docker.io/library/redis:8.10.2`; mount `/data`; companion command `["redis-server","--save","60","1"]`. | A small explicit persistence recipe. **T–medium:** resolve the repository’s prior fresh-volume/ownership failure before offering it. [Redis image](https://hub.docker.com/_/redis) |
| **Valkey snapshots** — Valkey projects | `valkey-data`; `2G`; `docker.io/valkey/valkey:9.1.2`; mount `/data`; companion command `["valkey-server","--save","60","1"]`. | Gives the volume a concrete application contract. **T–medium:** verify ownership and replacement recovery. [Valkey image](https://hub.docker.com/r/valkey/valkey) |
| **Grafana state** — dashboards and configuration | `grafana-data`; `5G`; `docker.io/grafana/grafana:13.2.3`; mount `/var/lib/grafana`; recorded owner `472:0`. | Matches the schema-2 ownership mechanism already used by the library. **Recorded owner; T–high** for the new standalone workflow. [Grafana storage](https://grafana.com/docs/grafana/latest/setup-grafana/configure-docker/) |
| **Prometheus metrics** — local time-series experiments | `prometheus-data`; `10G`; `docker.io/prom/prometheus:v3.15.0`; mount `/prometheus`; recorded owner `65534:65534`. | Separates metric storage from configuration. **Recorded owner; T–high** for recovery and the standalone workflow. [Prometheus storage](https://prometheus.io/docs/prometheus/latest/installation/) |
| **pgAdmin state** — database-browser configuration | `pgadmin-data`; `2G`; `docker.io/dpage/pgadmin4:9.18.0`; mount `/var/lib/pgadmin`; owner `5050:0`. | Provides the documented writable directory. Required application credentials remain in the app form. **T–high.** [pgAdmin deployment](https://www.pgadmin.org/docs/pgadmin4/latest/container_deployment.html) |
| **Qdrant collections** — vector-search experiments | `qdrant-data`; `10G`; `docker.io/qdrant/qdrant:v1.19.2`; mount `/qdrant/storage`. | Matches the collection-storage directory. **T–medium:** verify exact-image ownership and collection recovery. [Qdrant quickstart](https://qdrant.tech/documentation/quickstart/) |
| **Meilisearch indexes** — application-search development | `meilisearch-data`; `10G`; `docker.io/getmeili/meilisearch:v1.55.0`; mount `/meili_data`. | Makes index persistence explicit. **T–medium:** fresh-volume permission test required. [Meilisearch deployment](https://www.meilisearch.com/docs/resources/self_hosting/getting_started/docker) |
| **Mailpit messages** — mail-testing history | `mailpit-data`; `1G`; `ghcr.io/axllent/mailpit:v1.31.5`; mount `/data`; require companion `MP_DATABASE=/data/mailpit.db`. | Avoids a volume that the application never uses. **T–high.** [Mailpit database option](https://mailpit.axllent.org/docs/configuration/runtime-options/) |
| **NATS JetStream data** — messaging tests | `nats-data`; `5G`; `docker.io/library/nats:2.15.0`; mount `/data`; require command arguments `["-js","-sd","/data","-m","8222"]`. | Connects the volume to an explicit JetStream store directory. **T–high.** [NATS options](https://raw.githubusercontent.com/nats-io/nats-server/v2.15.0/server/opts.go) |
| **WordPress site files** — themes, plugins and uploads | `wordpress-data`; `5G`; `docker.io/library/wordpress:7.1-php8.4-apache`; mount `/var/www/html`. | Keeps site files independently persistent; the database still needs its own volume. **T–medium:** verify image initialisation onto an empty Apple volume. [WordPress image](https://hub.docker.com/_/wordpress) |
| **Ghost content** — publishing assets | `ghost-content`; `5G`; `docker.io/library/ghost:6.71.0`; mount `/var/lib/ghost/content`. | Uses the standard image’s content directory. **T–medium:** test initialisation and ownership; do not apply this contract to a different image variant. [Ghost image](https://hub.docker.com/_/ghost) |

The existing schema-2 ownership helper is valuable: it handles proven, newly created volumes through an app-controlled helper. It should remain constrained to that provenance and must not recursively change an existing user volume.

The standalone Volume form currently lacks the complete image/mount/owner contract. Extend its typed prefill and downstream attachment metadata before claiming that these presets prepare usable application storage. There is no proposed `volume create --owner`, mount-path flag or fabricated `--opt uid=…`.

**Networks: eight candidates**

Network presets should describe routing intent and address allocation. Names such as “frontend” and “backend” do not create access-control policies.

Blank subnet fields mean “let the runtime allocate.” Explicit IPv4 examples below use private address space, but **none is universally conflict-free**. Check overlap against runtime networks, host interfaces and routes, including VPN routes, before presenting the final value. [RFC 1918](https://www.rfc-editor.org/rfc/rfc1918.txt)

| Candidate and audience | Exact proposed prefill | Why this default; confidence |
|---|---|---|
| **Application network** — one ordinary application group | Name `app`; host-only `false`; IPv4 blank; IPv6 blank. Command: `container network create app`. | Least configuration for a normal group. **T–high:** retain the existing preset and verify connectivity under 1.5.0. |
| **Frontend network** — web and API services | `frontend`; host-only `false`; both subnets blank. Command: `container network create frontend`. | Useful organisational naming without pretending to enforce tier isolation. **T–high.** |
| **Host-only backend** — local databases and caches | `backend`; host-only `true`; both subnets blank. Command: `container network create --internal backend`. | Makes the routing difference explicit. **T–high:** test host access, peer access and blocked external egress. |
| **Project network with a stable subnet** — projects needing predictable addressing | `project-net`; host-only `false`; IPv4 candidate `192.168.240.0/24`; IPv6 blank. Command adds `--subnet 192.168.240.0/24`. | Useful for gateway-based wiring and repeatable development. **T–medium:** allocate a different `/24` if this one overlaps. |
| **Integration-test network** — a separate test deployment | `integration-net`; host-only `false`; IPv4 candidate `192.168.241.0/24`; IPv6 blank. | Separates a test group from the primary project network. **T–medium:** creation order and teardown must not damage other networks. |
| **Offline fixture network** — fixtures that should not reach external services | `fixtures-net`; host-only `true`; IPv4 candidate `192.168.242.0/24`; IPv6 blank. Command adds `--internal --subnet 192.168.242.0/24`. | A concrete host-only testing use case. **T–medium:** prove the intended reachability; the label alone is insufficient. |
| **Alternate-address project network** — hosts where the usual range overlaps | `project-alt`; host-only `false`; IPv4 candidate `10.203.40.0/24`; IPv6 blank. | Provides another allocation pool, subject to the same overlap checks. **T–medium:** do not describe it as automatically VPN-safe. |
| **IPv6 host-only lab** — developers testing dual-stack behaviour | `ipv6-lab`; host-only `true`; IPv4 candidate `192.168.243.0/24`; illustrative IPv6 `fd6b:3a2e:7f40:1::/64`; flags `--internal --subnet … --subnet-v6 …`. | Adds a distinct testing capability. **Blocked, then T–medium:** add IPv6 prefill support and generate a fresh ULA prefix for each deployment rather than shipping this illustrative prefix as a constant. [RFC 4193](https://www.rfc-editor.org/rfc/rfc4193.txt) |

Apple calls `--internal` host-only; its networking documentation should remain the terminology reference. [Apple networking](https://raw.githubusercontent.com/apple/container/1.5.0/docs/networking.md)

The repository’s current subnet allocator does not establish complete CIDR-overlap protection. Fixed subnets also do not cure the separate runtime bridge-collision failure recorded against 1.5.0. Test multiple networks through different start/stop orders before expanding this catalogue. [Upstream network issue](https://github.com/apple/container/issues/2051)

Several network entries are variants of one recipe. The detail pane can offer these variants together instead of making the list look larger through nearly identical rows.

**Domains: eight candidates**

Prefer `.test` for ordinary application development. `.internal` is useful for broader private naming. `.home.arpa` belongs to residential home-network use and should be an explicit homelab choice.

These are alternatives for the runtime’s **one active container-registration domain per host**. Creating `project.test` does not automatically give each group an independent DNS zone. Preserve the existing form’s behaviour: “Name containers under this domain” defaults on only when no active container domain exists; otherwise it defaults off.

For the first seven rows, the form kind is `containers`, the host-address field is empty, and the command operand is exactly the domain shown.

| Candidate and audience | Exact proposed prefill | Why this default; confidence |
|---|---|---|
| **General development** — most users | Domain `test`; command `container system dns create test`. | Short, purpose-appropriate namespace; `.test` and its descendants are reserved for testing. **T–high**, subject to the capture gap. [RFC 6761 §6.2](https://www.rfc-editor.org/rfc/rfc6761) |
| **Project development** — one project selected as the host’s active environment | `project.test`; command `container system dns create project.test`. Replace `project` with the validated project slug when context supplies one. | Adds meaningful context without using a public domain. **T–high:** test parent/child resolver coexistence. [RFC 6761](https://www.rfc-editor.org/rfc/rfc6761) |
| **Integration environment** — a host dedicated to test workloads | `ci.test`; command `container system dns create ci.test`. | Clear environmental naming. It does not create per-group DNS isolation. **T–high.** [RFC 6761](https://www.rfc-editor.org/rfc/rfc6761) |
| **Private services** — general private naming | `internal`; command `container system dns create internal`. | ICANN reserved `INTERNAL` from delegation for private-use applications. This is distinct from RFC-defined special resolver behaviour. **T–high.** [ICANN resolution](https://www.icann.org/en/board-activities-and-meetings/materials/approved-resolutions-special-meeting-of-the-icann-board-29-07-2024-en#section2.a) |
| **Private project** — a named private development environment | `project.internal`; command `container system dns create project.internal`. | More descriptive than a flat private namespace. **T–high:** apply the same active-domain and resolver checks. [ICANN resolution](https://www.icann.org/en/board-activities-and-meetings/materials/approved-resolutions-special-meeting-of-the-icann-board-29-07-2024-en#section2.a) |
| **Home network** — residential homelab users | `home.arpa`; command `container system dns create home.arpa`. | Standards-defined residential scope. **T–medium:** require review of an existing home-network resolver before claiming the whole suffix. [RFC 8375](https://www.rfc-editor.org/rfc/rfc8375) |
| **Home lab subdomain** — a lab within a residential network | `lab.home.arpa`; command `container system dns create lab.home.arpa`. | A narrower namespace than taking all of `home.arpa`. **T–medium:** validate resolver precedence and existing local use. [RFC 8375](https://www.rfc-editor.org/rfc/rfc8375) |
| **Reach this Mac** — containers calling a host service | Kind `host alias`; domain `host.container.internal`; address `203.0.113.113`; container-registration toggle off. Command: `container system dns create --localhost 203.0.113.113 host.container.internal`. | Retains Apple’s documented host-access convention. **Recorded convention; T–high:** test resolution and an actual host-service connection. [Apple command reference](https://raw.githubusercontent.com/apple/container/1.5.0/docs/command-reference.md) |

Do not describe `203.0.113.113` as inherently pointing to the host: RFC 5737 reserves its range for documentation; Apple’s explicit mapping gives it this role. [RFC 5737](https://www.rfc-editor.org/rfc/rfc5737.txt)

Do not offer `.local` as another generic development suffix; it has multicast-DNS semantics. [RFC 6762](https://www.rfc-editor.org/rfc/rfc6762.txt)

The review form must distinguish resolver installation from changing the active container domain, and explain any required container restart. DNS administration must continue through the existing privileged operation, not a library-supplied script.

**Machines: eight profiles, three proven image references**

The available evidence supports **three image references**, not eight distributions:

- `alpine:3.22`
- `almalinux/9-init:9.8-20261002`
- `almalinux/10-init:10.2-20261002`

The October repository record reports creation, boot, OS identification, login as the host user, stop and subsequent boot on `container` 1.5.0 for these entries. This supplements the older machine specification, which only established Alpine. AlmaLinux’s `-init` images are the relevant systemd-oriented variants. [AlmaLinux 9 init image](https://hub.docker.com/r/almalinux/9-init), [AlmaLinux 10 init image](https://hub.docker.com/r/almalinux/10-init)

The machine specification records failures for stock `ubuntu:24.04`, `debian:13`, `fedora:41` and `busybox:latest`. A successful pull or creation record is not evidence of a bootable machine. These images should not be added as machine suggestions on the strength of being valid OCI images.

Use the following image aliases only to keep the table readable:

- **A:** `alpine:3.22`
- **A9:** `almalinux/9-init:9.8-20261002`
- **A10:** `almalinux/10-init:10.2-20261002`

Each row expands to the machine-create command given earlier. Do not add `--set-default`, `--no-boot`, container volumes or container networks.

| Candidate and audience | Exact prefill: name; image; CPUs; memory; home mount | Why this default; confidence |
|---|---|---|
| **Alpine shell** — small Linux shell tasks | `alpine-box`; A; `2`; `2G`; `rw` | Retains the existing proven entry and sharing behaviour. **Recorded**, limited to the tested image reference and workflow. |
| **AlmaLinux 9 development** — projects targeting that distribution generation | `alma9-dev`; A9; `4`; `4G`; `rw` | Retains the proven systemd machine. **Recorded.** |
| **AlmaLinux 10 development** — projects targeting that generation | `alma10-dev`; A10; `4`; `4G`; `rw` | Retains the second proven AlmaLinux baseline. **Recorded.** |
| **Alpine without home sharing** — disposable shell experiments | `alpine-isolated`; A; `2`; `1G`; `none` | Offers an explicit file-sharing boundary with a small resource proposal. **T–high:** test login and absence of home sharing. |
| **Alpine source review** — tools that need to read host source files | `alpine-review`; A; `2`; `2G`; `ro` | Makes read-only sharing discoverable. **T–high:** verify reads succeed and writes to the shared home fail. |
| **Alpine build workspace** — users installing their own build tools | `alpine-build`; A; `4`; `4G`; `rw` | Adds headroom without pretending a compiler is preinstalled. **T–high:** test this resource/share profile and a representative user-installed tool. |
| **AlmaLinux 9 package lab** — package-building experiments | `alma9-build`; A9; `6`; `8G`; `none` | A larger, unshared workspace. **T–high:** validate resources, login and reboot; packages remain user-installed. |
| **AlmaLinux 10 service lab** — systemd service experiments | `alma10-services`; A10; `8`; `8G`; `none` | Gives service experiments room while avoiding automatic home exposure. **T–high:** test service lifecycle and machine reboot. |

The new profiles are sizing and sharing proposals, not additional boot-proven images. Group them beneath the three distributions if eight separate rows feel repetitive.

The machine suggestion type needs a `homeMount` field to express these profiles. The current form also treats arbitrary `alpine:*` references too broadly as known-good. Replace that inference with evidence tied to the tested image and resolved digest.

Keep the existing machine start/login implementation. The recorded workaround uses `machine run` to ensure a boot; there is no supported `machine start` command to invent.

**Clusters: eight candidates**

The compiled catalogue supplies a sensible node-image baseline, but the inspected evidence does not establish a successful live cluster lifecycle. **All eight candidates, including the existing three, require live tests before being represented as verified.**

Define these exact node-image values:

```text
K135 = docker.io/kindest/node:v1.35.5@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95

K134 = docker.io/kindest/node:v1.34.8@sha256:02722c2dedddcfc00febf5d27fbeb9b7b2c14294c82109ff4a85d89ac9ba3256

K136 = docker.io/kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5
```

These references are published by kind; that establishes their provenance, not compatibility with Apple’s wrapper. Keep both tag and digest. [kind v0.32.0 release](https://github.com/kubernetes-sigs/kind/releases/tag/v0.32.0)

Each row maps to `container k8s create --name … --cpus … --memory … --node-image …`, adding `--rm` only where specified.

| Candidate and audience | Exact prefill | Why this default; confidence |
|---|---|---|
| **Starter** — learning manifests | Name `k8s-starter`; CPUs `2`; memory `2G`; K135; disposable `false`. | Retains the smallest existing proposal. **T–medium:** prove it has useful workload headroom. |
| **Compact development** — small applications on constrained hosts | `k8s-compact`; `2`; `4G`; K135; `false`. | An intermediate memory choice without adding CPUs. **T–medium.** |
| **Standard development** — several development workloads | `k8s-dev`; `4`; `8G`; K135; `false`. | Retains the existing general-purpose proposal. **T–medium.** |
| **Build and integration lab** — heavier test workloads | `k8s-build`; `6`; `12G`; K135; `false`. | More proposed headroom for concurrent work. **T–medium:** does not install a build system. |
| **Metrics lab** — experimenting with observability workloads | `k8s-metrics`; `6`; `16G`; K135; `false`. | A memory-oriented profile. **T–medium:** no metrics stack is installed by this preset. |
| **Disposable test cluster** — short-lived experiments | `k8s-test`; `2`; `2G`; K135; `true`, producing `--rm`. | Makes removal-on-stop explicit. **T–medium:** verify cleanup and kubeconfig handling. |
| **Kubernetes 1.34 compatibility** — testing an older target version | `k8s-compat-134`; `4`; `8G`; K134; `false`. | A version-specific compatibility lane. **T–medium:** the alternate node image needs a full Apple-runtime test. |
| **Kubernetes 1.36 evaluation** — testing a newer target version | `k8s-eval-136`; `4`; `8G`; K136; `false`. | Allows deliberate evaluation without changing the default. **T–medium:** compatibility is unproven. |

These resource sizes are editorial starting points, not upstream minimums or performance guarantees. Apply host-capacity validation before committing.

Do not imply multi-node or high-availability topology: the proposed form values contain no such configuration, and the captured command has no `--nodes` or `--workers` flag. Although 1.5.0 captures `--cni`, these suggestions should retain the runtime’s default CNI rather than introduce a manifest-path requirement.

**Images: add a tab, after the core consolidation**

An Images tab has a distinct purpose if it offers **pull-only development bases**. Its action should say **Pull Image**, open the existing pull form, and create no container, ports, mounts or environment.

The exact common prefill is `platform=linux/arm64`, `scheme=https`, with the reference below. All are **T–high** candidates: verify the exact ARM64 manifest, pull it using 1.5.0, and run a suitable shell or version smoke test before publication.

| Candidate and audience | Exact image reference | Why this default |
|---|---|---|
| **Alpine base** — small shell and image-build tasks | `docker.io/library/alpine:3.22.6` | A patch-specific base. It must not inherit machine-boot verification from another reference. [Official image](https://hub.docker.com/_/alpine) |
| **Ubuntu 24.04 base** — Ubuntu application containers | `docker.io/library/ubuntu:noble-20260930.1` | A dated distribution base; label it for containers, not as a verified machine. [Official image](https://hub.docker.com/_/ubuntu) |
| **Debian 13 slim** — Debian application containers | `docker.io/library/debian:trixie-20261005-slim` | A dated slim base with an explicit distribution generation. [Official image](https://hub.docker.com/_/debian) |
| **Python development base** — Python projects | `docker.io/library/python:3.14.8-slim-bookworm` | Specifies both language version and base family. [Official image](https://hub.docker.com/_/python) |
| **Node.js development base** — JavaScript and TypeScript projects | `docker.io/library/node:24.22.0-bookworm-slim` | A versioned Node 24 base rather than a moving `latest`. [Official image manifest](https://raw.githubusercontent.com/docker-library/official-images/master/library/node) |
| **Go build base** — Go projects | `docker.io/library/golang:1.27.2-bookworm` | A versioned compiler image suitable for subsequent build configuration. [Official image](https://hub.docker.com/_/golang) |
| **Rust build base** — Rust projects | `docker.io/library/rust:1.99.1-bookworm` | An explicit compiler version and base family. [Official image](https://hub.docker.com/_/rust) |
| **Swift 6.2 base** — Swift-on-Linux work | `docker.io/library/swift:6.2.4-noble` | A version-specific Swift environment aligned with the project’s language generation. [Official image](https://hub.docker.com/_/swift) |

Avoid duplicating every app image as another suggestion. App details can expose “Pull image only” as a secondary action. Search results should distinguish **recipe**, **suggested image** and **image already on this host**.

**Registries: do not add a separate tab**

Q20 already provides the relevant discovery model: initial Docker Hub and GHCR rows, additional known providers through Add Registry, and custom hosts for account-specific registries.

A second catalogue would mostly repeat provider names and icons. It would also risk confusing “known registry”, “added registry” and “authenticated registry”.

Keep registry names, aliases and descriptions searchable through the global navigation search. A result should open the existing Add Registry form with the provider and `scheme=https` filled in. Account-specific hosts remain required input. Authentication continues through the existing username and password-stdin path; suggestions contain no credentials.

Registry display metadata and artwork can move into the signed library without creating another Suggestions tab. Host validation and authentication behaviour stay compiled.

**Catalogue ownership and schema design**

Use the signed library as the authoring source, and generate the bundled fallback from the same validated data. This avoids maintaining two independently edited catalogues.

| Catalogue | Recommended home | What remains compiled |
|---|---|---|
| Apps and stacks | Existing signed library | Container/group planning, secret handling, mount preparation, allowed argument construction |
| Volumes | Signed typed entries with image compatibility, mount contract and optional owner | Volume creation, provenance checks and ownership helper |
| Networks | Signed intent presets and allocation preferences | CIDR validation, overlap detection, allocation and command construction |
| Domains | Signed names, purpose and reservation references | Reserved-name rules, active-domain handling, privileged resolver operations |
| Machines | Signed exact image references, profiles and test evidence | Boot/login lifecycle, host limits, home-sharing controls and compatibility checks |
| Clusters | Signed node-image pins and resource profiles | Runtime capability checks, creation, kubeconfig handling and cleanup |
| Images | Signed pull-only references | Platform validation and pull execution |
| Registries | Signed descriptive metadata and artwork where useful | Custom-host validation, authentication and transport rules |

Keeping everything compiled would simplify review and guarantee that data changes travel with a particular app build. It would also require an app release for every image correction, retired entry, new profile or updated test record.

Moving data into the signed library allows faster corrections and growth, but increases the importance of schema validation, compatibility gating and publishing discipline. A signature establishes the origin and integrity of the catalogue bytes. It does not prove that a recipe ran successfully, or freeze the contents of a mutable image tag.

The concrete migration should be:

1. **Introduce schema 3 with typed resource payloads.** Schema 2 currently accepts only `container` and `stack`; adding other kinds to that enum would make old clients reject the file. Maintain a schema-2 feed during transition, or retain a compatible endpoint and fallback policy.
2. **Keep recipes declarative.** New kinds receive bounded typed fields. Do not add arbitrary CLI fragments, shell scripts, host paths or executable setup hooks.
3. **Preserve schema-2 ownership support.** `volumeOwner` already exists. Expand its safe reuse rather than designing another chown mechanism.
4. **Extend `check_entries.py` and the Swift validator together.** The Swift parser remains authoritative. Both should validate each kind’s fields, references, bounds, compatibility requirements and test evidence.
5. **Generate the fallback from accepted entries.** Give each entry a stable ID and revision so fetched and bundled content have deterministic replacement semantics.

The existing `artwork` facility is suitable for signed image metadata and cached icons, with its hash, size and decoding limits retained. Its current `distro.*` and `registry.*` namespace is not a general resource catalogue. Use system glyphs for generic resources unless a new artwork namespace is deliberately specified.

Keep the existing Ed25519 publication process, last-known-good cache and rollback protection. Publishing a catalogue should remain a reviewed act; automated tag discovery should propose changes and clear obsolete test evidence, not silently bless a new image.

**Make “tested” specific enough to be useful**

The current `tested` object records a date and number of Macs. Preserve that historical information, but add structured evidence for new revisions:

| Field | Purpose |
|---|---|
| Recipe revision/hash | Identifies the exact fields exercised |
| CLI version, macOS version and architecture | Records the execution environment |
| Resolved image digest or digests | Prevents a changed tag from inheriting old verification |
| Test date and Mac count | Retains existing useful metadata |
| Test-suite results | Separates launch, persistence, wiring, boot and cleanup evidence |
| Nonpersonal evidence identifier | Links review to a reproducible test record without embedding personal details |
| Capability requirements | Hides incompatible entries on the selected host |
| Retirement/replacement status | Allows withdrawal without deleting resources users already created |

Do not convert old `tested` records into claims about suites that were never recorded. Any material recipe change should require the relevant tests again.

For publication, the minimum meaningful checks are:

| Area | Required live evidence |
|---|---|
| Apps | Exact image pulls; service performs its advertised operation; generated credentials work |
| Stateful apps and volumes | Fresh-volume initialisation; write data; remove and recreate the container; recover that data |
| Stacks | Dependency readiness, shared secrets, DNS and supported gateway wiring, collision-adjusted ports |
| Networks | Host/peer/egress behaviour, overlap rejection, coexistence, different creation and teardown orders |
| Domains | Resolver installation, intended resolution, active-domain change, restart behaviour and removal |
| Machines | Boot, OS identification, intended init process, login, sharing mode, stop and reboot |
| Clusters | Creation, usable kubeconfig, node Ready, a running workload, stop/recreation and cleanup |
| Images | Exact-platform pull plus a suitable runtime smoke test |

Research candidates should stay out of the ordinary usable picker until these gates pass. An internal preview can show them as unavailable, with the missing evidence clearly identified.

**Consolidated section and form handoff**

Use this top-level tab order:

`All · Apps · Stacks · Volumes · Networks · Domains · Machines · Clusters · Images`

Images can arrive later without changing the model. Categories such as databases, development and observability remain filters within the relevant tabs. Use an accessible scrolling tab strip at narrower widths.

Apply Q58 directly: a bounded list on the left and selection details on the right, using the shared split-pane implementation and persisted width. No selection shows an explanatory empty detail; multiple selection shows a summary. Preserve keyboard selection, pane navigation and the narrow-window detail behaviour.

Apply the latest Q56 rule: **rows throughout**, including resource suggestions. The existing app/stack list already supplies a useful starting point. Replace the resource gallery’s remaining card grid.

A row needs a name, short purpose, kind and compact compatibility/test status. The detail pane supplies the image or resource values, ports, mounts, sharing behaviour, sources and test date. Long digests and full environment lists belong in details.

“Use This Suggestion” should perform the following handoff:

1. Resolve the selected host and verify that the entry is compatible with it.
2. Produce a typed prefill for the existing resource form.
3. Open that form full-width, outside the list/detail split.
4. Let the user review and edit all values.
5. Execute only through the form’s existing commit path.

Apps go to the container form; stacks to the group/stack form; the five resource kinds to their own create forms; Images to the pull form. There should be no parallel set of suggestion-specific creation forms.

Keep the Q64/Q65 form-header actions. Treat the prefill as the form’s initial baseline so merely opening a suggestion does not create a false dirty-state warning.

Store the return route, selected tab, query, row selection, scroll position and host in root-owned UI state. On cancel or completion, restore that context. The current view-local state is insufficient if navigating to a form reconstructs the Suggestions view.

Retain sequential review for a supported multi-selection: “Use 3” opens three forms with Skip and Close controls. Initially restrict batches to compatible kinds and hosts. Do not make a mixed DNS/machine/cluster selection imply one atomic operation.

**Search through the existing ⌘K box**

Keep one toolbar search field under Q55.

Within Suggestions, a query should search the complete catalogue. Tabs show matching counts and act as kind filters; All displays every matching kind. If the current tab has no matches but others do, show a direct “Show all matches” action.

Index titles, descriptions, categories, image repositories, supported image versions, resource names and useful terms such as “host-only”, “read-only home” and “persistent mail”.

Extend the existing global `suggestion:` scope to all catalogue kinds. Preserve the meaning of existing resource scopes: for example, `image:` should continue to find host images rather than silently switching to suggested pulls. Existing command-only and navigation syntax should remain unchanged.

Search results should open the matching tab and detail, not execute a suggestion. Preserve Q55’s focus and keyboard ownership rules.

**Current section entry points**

Remove the Suggestions buttons from individual “new” forms. Each resource section retains its ordinary New action.

Where an empty state or menu needs a discovery shortcut, make it a deep link to the corresponding consolidated tab. It should not open another gallery or insert a picker into the form.

This gives users one place to browse while keeping direct creation fast.

**Reuse in a group’s Add Service picker**

The in-progress picker already separates suggested apps, host images and a blank service. Preserve that task-specific flow.

Share the catalogue store, filtering, rows, artwork, details and typed app-to-service conversion. Do not force the complete Suggestions view—with resource tabs and batch-creation routing—into the group editor.

For a group:

- Suggested apps become draft service members through the shared group-member factory.
- A single selection can open the existing service review form.
- Multiple selections add reviewable drafts without pulling images or starting containers.
- Host-image selections remain available alongside suggestions.
- Stack suggestions remain a group-level operation; do not silently flatten another stack into an existing group.
- Machine, cluster and domain suggestions are not services.

Carry over ports, environment, command arguments, volume contracts, owner metadata and required secret references. Allocate names and ports against the destination group and host.

The current repository-only matching for host images deserves correction: a local image must not inherit another major version’s mount contract merely because the repository name matches. PostgreSQL’s version-dependent storage layout makes this a concrete failure case.

Keep Q29’s configuration-file workflow separate. A library entry is a maintained recipe; an exported configuration is a reviewed resource definition. Catalogue schema 3 and configuration schema 2 are different version spaces. Export should continue to exclude secrets, host folders and volume contents.

**Comparable products and what to borrow**

| Product | Observed organisation | Implication for Flotilla |
|---|---|---|
| **OrbStack** | Machine creation centres on supported distributions and versions, with resource configuration. [Machine documentation](https://docs.orbstack.dev/machines/) | Borrow the distinction between a supported machine distribution and an arbitrary container image. Keep the verified machine set deliberately small. |
| **Docker Desktop** | Extensions add functionality through a marketplace; Compose samples provide application recipes. These are different concepts. [Extensions](https://docs.docker.com/extensions/), [WordPress sample](https://docs.docker.com/reference/samples/wordpress/) | Treat Flotilla suggestions as editable recipes, not installed plugins. Borrow searchable discovery, but retain resource forms as the execution boundary. |
| **Portainer** | Application templates lead to editable deployment parameters, with a structured template format for containers and stacks. [Application templates](https://docs.portainer.io/user/docker/templates/application), [format](https://docs.portainer.io/advanced/app-templates/format) | This is the closest functional model: catalogue → detail → editable deployment. Borrow typed defaults and clear inputs, not Docker-specific flags. |
| **Coolify** | Its one-click service catalogue organises services for resource creation and includes service-specific setup information. [Service catalogue](https://coolify.io/docs/services/overview) | Show first-use requirements and what remains to configure. A ready image is not necessarily a ready application. |
| **CapRover** | One-click apps use a maintained catalogue and support additional template repositories. [One-click apps](https://caprover.com/docs/one-click-apps.html) | Externalising content supports growth. Flotilla should preserve its stronger signed-feed boundary rather than immediately accepting arbitrary third-party catalogues. |
| **UTM** | The official gallery has been retired; the linked community gallery is not made or reviewed by UTM, and older official images are no longer maintained. [Gallery notice](https://getutm.app/gallery/) | A gallery creates an ongoing maintenance obligation. Include retirement, replacement and test-age handling from the start. |

Docker Desktop’s retired Dev Environments feature should not be presented as a current template model. [Docker retired features](https://docs.docker.com/retired/)

**Recommended build order**

1. **Establish the evidence baseline.** Capture missing DNS help, reconcile compiled and fetched entries, correct overly broad machine verification, and prioritise the Mailpit/NATS persistence fixes.
2. **Consolidate discovery using existing data.** Add the tabs, shared rows, Q58 split view, root-owned navigation state and typed handoff to existing forms. Remove the form-level galleries.
3. **Complete Add Service reuse.** Share app recipes and rendering while preserving the group editor’s draft workflow; fix version-sensitive image matching.
4. **Introduce the expanded signed schema.** Add typed resource payloads, matching validators, richer test evidence, compatibility gating, retirement and a generated bundled fallback.
5. **Publish tested additions in small batches.** Start with straightforward apps, corrected persistence contracts and useful volume presets. Follow with networks and domains after host-level tests.
6. **Expand machines and clusters only after lifecycle tests.** Keep the three proven machine images; qualify new profiles and every cluster recipe separately.
7. **Add the pull-only Images tab.** Keep registry discovery in Add Registry and measure whether the new tab adds useful discovery beyond app details.
