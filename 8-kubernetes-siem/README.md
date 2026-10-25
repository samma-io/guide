# 8. The SIEM on Kubernetes

The SIEM from chapters 6 and 7 also runs inside a Kubernetes cluster. It uses the same services, the
same Sigma rules and the same alert format. Only the plumbing changes. On AWS the services talk
through S3 and SQS. In Kubernetes they talk through **NATS JetStream**, alerts are stored in
**PostgreSQL**, and the archive goes to **MinIO** or any S3-compatible store.

Everything is installed by one Helm chart, `chart/samma-siem` in the
[siem](https://github.com/samma-io/siem) repo.

## What you will learn

- How a log record becomes an alert row in Postgres over NATS.
- Which streams, subjects and consumers the services use.
- How to install the chart: lanes, Secrets, MinIO or your own S3, Postgres, Quickwit and Grafana.
- How to add a Sigma rule and how to change the alert routes.
- How to reach Grafana and Quickwit, and where every piece of data is kept.
- What is not on Kubernetes yet.

## How the data flows

```
 ingester               Vector                  detection-engine          alert-destination
 one per SaaS source    one                     one per lane              one
      │                    │                         │                         │
      ▼                    ▼                         ▼                         ▼
 samma.raw.<lane> ─► envelope VRL ─► samma.logs.<lane> ─► Sigma rules ─► samma.alerts.<lane> ─► routes ─► Postgres
   (SIEM_RAW)                          (SIEM_LOGS)                         (SIEM_ALERTS)               siem_alerts
                                            │                                   │
                                            ▼                                   ▼
                                       siem-storage ──────────────────────► siem-storage
                                       Postgres siem_events, S3 archive     S3 archive (alerts/)

 Grafana ─► Quickwit (search; metastore in Postgres, index on S3)
         └► Postgres siem_alerts (read-only login)
```

1. **Pull.** The ingester reads a SaaS audit API (for Google Workspace, the Admin Reports API) in
   time slices. It publishes one vendor-native record per message on `samma.raw.<lane>`, keyed by
   the record's dedupe key. Its slice queue is the stream `INGESTER_SLICES`, and it keeps its
   watermarks in Postgres (`ingester_checkpoint`).
2. **Normalise.** Vector reads `samma.raw.<lane>` from the durable consumer `vector-<lane>`. It adds
   the envelope every lane shares (`source`, `feed`, `event_time`, `actor_email`, `search_text`) and
   publishes the filtered record on `samma.logs.<lane>`. It is the same VRL the AWS pipeline runs. It
   acks the raw message only once the filtered record is stored.
3. **Detect.** `detection-engine` pulls from the durable consumer `detection-engine-<lane>` and runs
   that lane's Sigma rules on every record. It publishes each match to `samma.alerts.<lane>`, and
   only then acks the log message.
4. **Route.** `alert-destination` pulls from the consumer `alert-destination`, picks the
   destinations from its routing table, and inserts the alert into `siem_alerts`. It acks the
   alert only after the row is written.
5. **Store.** `siem-storage` reads the same streams through consumers of its own. It writes every
   filtered record to the `siem_events` table and archives records and alerts to S3.

**Duplicates are safe at every step.**
- A raw record re-read by a reconcile pass carries the same dedupe key, and `SIEM_RAW` drops it
  inside its 2-hour duplicate window.
- An alert's id comes from the rule and the record's position in the stream (`nats:SIEM_LOGS`,
  `<subject>/<sequence>`). A redelivered message therefore produces the same id.
- JetStream drops a republished alert inside its 2-minute duplicate window.
- `siem_alerts` has one row per id, and `siem_events` one row per subject, sequence and line.

**What happens on failure.** A message that keeps failing is redelivered up to 5 times
(`MaxDeliver`) and then left in the stream until its age or byte limit. That is the NATS
equivalent of the SQS dead-letter queue.

The full contract is in the `aws-siem` repo: `docs/contracts/detection-alert-v1.md`, section
"NATS transport", and `docs/contracts/nats-transport.md`.

## Streams and subjects

| Stream | Subjects | Kept for | Consumers |
|---|---|---|---|
| `INGESTER_SLICES` | `samma.ingester.slices.<source>` | work queue, 24h, 10MiB | `ingester-<source>` |
| `SIEM_RAW` | `samma.raw.<lane>`, for each lane with raw records | 24h, 100MiB | `vector-<lane>` |
| `SIEM_LOGS` | `samma.logs.<lane>`, for each lane | 7 days, 400MiB | `detection-engine-<lane>`, `storage-logs`, `storage-s3-logs` |
| `SIEM_ALERTS` | `samma.alerts.>` | 30 days, 200MiB | `alert-destination`, `storage-s3-alerts` |

| Consumer | AckWait | Why that value |
|---|---|---|
| `vector-<lane>` | 60s | Vector acks once the record is in `SIEM_LOGS` |
| `detection-engine-<lane>` | 300s | equal to the engine's `ENGINE_VISIBILITY_TIMEOUT` |
| `alert-destination` | 120s | above its 60s message timeout |
| `ingester-<source>` | 20m | above the ingester's 15-minute message timeout |
| `storage-logs` | 60s | a batch of 100 committed to `siem_events` well within it |
| `storage-s3-logs` | 6m | above the 5-minute S3 flush; a message is acked only once its object is written |
| `storage-s3-alerts` | 2m | one object per alert |

The chart creates the streams and consumers, not the services. A hook Job, `<release>-streams`,
runs after every install and upgrade. It creates what is missing and edits what exists to match,
so running it again changes nothing. detection-engine refuses to start if its consumer filters a
different subject than its lane. That stops one lane's rules from running on another lane's
events.

**Only deployed lanes are captured, never `samma.logs.>`.** The older Samma pipeline publishes
high-volume cluster logs under `samma.logs.k8s` and `samma.logs.k8s.audit` (about 11 MiB/min). A
stream on `samma.logs.>` would fill its byte cap within the hour.

**The byte caps must fit the JetStream volume.** They add up to 710 MiB against the 1Gi default
PVC (`nats.config.jetstream.fileStore.pvc.size`). Raise the caps and the PVC together, never the
caps alone.

## Install the chart

You need:
- a cluster running Kubernetes 1.25 or later, with an amd64 node, because the images are
  linux/amd64
- a default StorageClass, for the NATS and MinIO volumes
- a PostgreSQL with the TimescaleDB extension, for example the TimescaleDB of the Samma scanner
- Helm 3 or 4

The chart is installed from git. Its two dependencies (NATS and MinIO) are pinned in `Chart.lock`
but not committed, so fetch them first:

```bash
git clone https://github.com/samma-io/siem.git
cd siem
helm repo add nats https://nats-io.github.io/k8s/helm/charts/
helm repo add minio https://charts.min.io/
helm dependency build chart/samma-siem
```

### 1. The database and its Secret

Give the SIEM its own `siem` database and role, so it cannot touch scanner data. Run this once as a
Postgres admin:

```sql
CREATE ROLE siem LOGIN PASSWORD '<a new password>';
CREATE DATABASE siem OWNER siem;
REVOKE ALL ON DATABASE siem FROM PUBLIC;
\c siem
CREATE EXTENSION IF NOT EXISTS timescaledb;   -- siem_events is a hypertable
```

The chart never creates this Secret and deploys no Postgres. It reads the DSN from the Secret
`siem-postgres`, key `dsn` (`postgres.existingSecret`, `postgres.dsnKey`):

```bash
kubectl create namespace samma-siem
kubectl -n samma-siem create secret generic siem-postgres \
  --from-literal=dsn='postgres://siem:<password>@<postgres-host>:5432/siem?sslmode=disable'
```

Each service creates its own tables when it starts:

| Table | Created by |
|---|---|
| `siem_alerts`, `alert_ledger` | alert-destination |
| `siem_events` | siem-storage |
| `ingester_checkpoint` | ingester |

### 2. Your values

Start with a small values file. The defaults install NATS, MinIO, every pipeline service and the
`workspace` lane:

```yaml
# siem-values.yaml
lanes:
  - workspace
nats:
  natsBox:
    enabled: true   # a shell with the nats CLI, used in the smoke test below
```

### 3. Install

```bash
helm upgrade --install samma-siem chart/samma-siem -n samma-siem -f siem-values.yaml
kubectl -n samma-siem logs job/samma-siem-streams
kubectl -n samma-siem get deploy
```

Until the streams Job has created their consumers, the workloads exit at start and are restarted.
That is expected on a first install. `helm status samma-siem -n samma-siem` prints what was
installed.

With the release name `samma-siem`, everything is called `samma-siem-<part>`:

| Deployment | What |
|---|---|
| `samma-siem-ingester-google-workspace` | the Workspace puller, at `replicas: 0` until it has a credential |
| `samma-siem-vector` | `samma.raw.workspace` to `samma.logs.workspace` |
| `samma-siem-detection-engine-<lane>` | one per lane, with a Service on `:9090` (health, metrics, `/rules`) |
| `samma-siem-alert-destination` | the alert router |
| `samma-siem-siem-storage` | `siem_events` and the S3 archive |
| `samma-siem-quickwit`, `samma-siem-grafana` | only when you turn them on, see below |

Nothing is exposed outside the cluster. Every Service is ClusterIP and the chart renders no
Ingress.

### Lanes

Each entry in `lanes` adds `samma.logs.<lane>` to `SIEM_LOGS`, a `detection-engine-<lane>`
consumer and Deployment, and the storage consumers' filter. A lane with raw records also gets
`samma.raw.<lane>` in `SIEM_RAW` and a `vector-<lane>` consumer. Write `{name: <lane>, raw: false}`
for a lane without raw records. Adding a lane is a values change and an upgrade. Size
`streams.logs.maxBytes` for the new lane's volume.

The default image of detection-engine (`d5d7439`) knows the SaaS lanes only. The `k8s` and
`scanner` lanes and their rules are in detection-engine `main` from `0c5b5ce` on. That image is not
published yet, so build it first (see [Add a Sigma rule](#add-a-sigma-rule), step 4), then:

```yaml
# k8s-lane.yaml
lanes:
  - workspace
  - {name: k8s, raw: false}   # Kubernetes audit events, no raw records
detectionEngine:
  tag: 0c5b5ce                # an image built from detection-engine main, 0c5b5ce or later
```

```bash
helm upgrade --install samma-siem chart/samma-siem -n samma-siem -f siem-values.yaml -f k8s-lane.yaml
```

Nothing in the chart publishes to `samma.logs.k8s` or `samma.logs.scanner` yet. See
[What is not on Kubernetes yet](#what-is-not-on-kubernetes-yet).

### MinIO or your own S3

By default the chart installs MinIO with one 10Gi volume and creates the bucket
`samma-siem-archive` with a hook Job. siem-storage and Quickwit use the MinIO root Secret,
`samma-siem-minio` (keys `rootUser` and `rootPassword`), which MinIO generates at install.

To use another S3-compatible store, turn MinIO off and point the chart at it. Create the bucket
yourself; the chart only creates it in MinIO.

```bash
kubectl -n samma-siem create secret generic siem-s3 \
  --from-literal=accessKeyId='<access key id>' \
  --from-literal=secretAccessKey='<secret access key>'
```

```yaml
# external-s3.yaml
minio:
  enabled: false
s3:
  endpoint: https://s3.eu-north-1.amazonaws.com
  region: eu-north-1
  bucket: acme-siem-archive
  existingSecret: siem-s3       # keys accessKeyId, secretAccessKey
  forcePathStyle: false         # true for MinIO and most self-hosted stores
```

`helm template` cannot read the cluster, so with an empty `minio.rootUser` it generates new MinIO
credentials on every render. If a GitOps tool renders the chart, create the Secret yourself and set
`minio.existingSecret`.

### A NATS you already run

```yaml
# external-nats.yaml
nats:
  enabled: false
externalNats:
  url: nats://nats.samma.svc:4222   # must have JetStream enabled
```

The streams Job then creates or edits the four streams on that server. There is no
`samma-siem-nats-box` then; use the nats CLI of that NATS.

### Quickwit and Grafana

Both are off by default. Their images are not published: they are built and pushed by hand, so
there is no tag to default to, and each needs a Secret that only you can create. Turn them on
together, because Grafana's Quickwit datasources point at this release's Quickwit.

**The images.** Build them from sibling checkouts of `aws-siem`, `quickwit` and `grafana`, with
`quickwit` at `10d8377` or later (`QW_MODE=k8s`) and `grafana` at `4103e8f` or later
(`provisioning-k8s`). Each image is tagged with its repo's short git sha:

```bash
echo "$GHCR_TOKEN" | docker login ghcr.io -u <github-user> --password-stdin
aws-siem/hack/build-images.sh quickwit grafana
git -C quickwit rev-parse --short HEAD   # quickwit.tag
git -C grafana rev-parse --short HEAD    # grafana.tag
```

If the packages are private, add a pull Secret to `workloads.imagePullSecrets`.

**The Quickwit metastore.** Quickwit keeps its metastore in a Postgres database of its own and runs
its own migrations there. Its index data goes to `s3://<s3.bucket>/quickwit/indexes`.

```sql
CREATE ROLE quickwit LOGIN PASSWORD '<a new password>';
CREATE DATABASE quickwit OWNER quickwit;
```

```bash
kubectl -n samma-siem create secret generic siem-quickwit-metastore \
  --from-literal=uri='postgres://quickwit:<password>@<postgres-host>:5432/quickwit'
```

**A read-only login for Grafana.** Grafana's Postgres datasource runs whatever SQL a dashboard
editor types, so read-only has to be enforced by the database. Run this in the `siem` database
after the first install, because `siem_alerts` must exist first:

```sql
CREATE ROLE siem_alerts_reader NOLOGIN;
GRANT CONNECT ON DATABASE siem TO siem_alerts_reader;
GRANT USAGE ON SCHEMA public TO siem_alerts_reader;
GRANT SELECT ON siem_alerts TO siem_alerts_reader;

CREATE ROLE grafana_siem LOGIN PASSWORD '<a new password>' IN ROLE siem_alerts_reader;
ALTER ROLE grafana_siem SET default_transaction_read_only = on;
```

```bash
kubectl -n samma-siem create secret generic siem-grafana \
  --from-literal=admin-password="$(openssl rand -base64 24)" \
  --from-literal=postgres-host='<postgres-host>' \
  --from-literal=postgres-database=siem \
  --from-literal=postgres-user=grafana_siem \
  --from-literal=postgres-password='<the grafana_siem password>'
```

Optional keys: `admin-user` (default `admin`), `postgres-port` (`5432`) and `postgres-sslmode`
(`require`; set `disable` for a database without TLS). Never give Grafana the `siem-postgres`
Secret: that role owns and writes the tables, and the chart refuses it.

```yaml
# search.yaml
quickwit:
  enabled: true
  tag: 10d8377                  # your quickwit image
  metastore:
    existingSecret: siem-quickwit-metastore
grafana:
  enabled: true
  tag: 4103e8f                  # your grafana image
  existingSecret: siem-grafana
```

```bash
helm upgrade --install samma-siem chart/samma-siem -n samma-siem -f siem-values.yaml -f search.yaml
```

On start, Quickwit creates its four indexes: `logs-saas`, `logs-k8s`, `logs-scanner` and `alerts`.
Check them with:

```bash
kubectl -n samma-siem exec deploy/samma-siem-quickwit -- quickwit index list
```

Quickwit has no authentication. Its Service is ClusterIP, and a NetworkPolicy admits port 7280
only from this release's Grafana and Vector. That needs a CNI that enforces NetworkPolicy.

Grafana keeps nothing: dashboards and datasources come from the image, and its data directory is
an emptyDir. A restart forgets users made in the UI.

### Smoke test

The `workspace` lane ships two critical rules: "Admin Role Granted" and "Two-Step Verification
Disabled".

**From the raw end.** Publish two raw Admin Reports activities, shaped exactly as the ingester
writes them. The first should fire and the second should not:

```bash
for n in ASSIGN_ROLE UNASSIGN_ROLE; do
  kubectl -n samma-siem exec deploy/samma-siem-nats-box -- nats pub samma.raw.workspace \
    "{\"kind\":\"admin#reports#activity\",\"id\":{\"time\":\"$(date -u +%FT%TZ)\",\"applicationName\":\"admin\",\"uniqueQualifier\":\"smoke-$n\"},\"actor\":{\"email\":\"smoke@example.com\"},\"type\":\"DELEGATED_ADMIN_SETTINGS\",\"name\":\"$n\"}" \
    -H "Nats-Msg-Id:smoke-$n-$(date +%s)"
done
```

Vector turns each one into a filtered record on `samma.logs.workspace`, with `feed` set to `admin`
and `actor_email` set to `smoke@example.com`. Publishing the same `Nats-Msg-Id` again within two
hours is dropped by `SIEM_RAW`.

**From the filtered end.** Publish straight to the lane, one record that fires and one that does
not:

```bash
kubectl -n samma-siem exec deploy/samma-siem-nats-box -- nats pub samma.logs.workspace \
'{"source":"workspace","feed":"admin","actor_email":"smoke@example.com","type":"DELEGATED_ADMIN_SETTINGS","name":"ASSIGN_ROLE"}
{"source":"workspace","feed":"admin","actor_email":"smoke@example.com","type":"DELEGATED_ADMIN_SETTINGS","name":"UNASSIGN_ROLE"}'
```

Here is what you should see:

```bash
kubectl -n samma-siem logs deploy/samma-siem-detection-engine-workspace --tail=3
# "object complete" ... "matched":1,"published":1

kubectl -n samma-siem logs deploy/samma-siem-alert-destination --tail=3
# "routing decided" ... "destinations":["postgres:siem_alerts"]

kubectl -n samma-siem exec deploy/samma-siem-nats-box -- nats consumer info SIEM_LOGS detection-engine-workspace
# no pending or unacknowledged messages
```

```sql
-- in the siem database
SELECT alerted_at, level, rule_title, provenance->>'key' AS key
FROM siem_alerts ORDER BY alerted_at DESC LIMIT 5;
-- critical | Google Workspace Admin Role Granted | samma.logs.workspace/<seq>

SELECT lane, count(*) FROM siem_events GROUP BY lane;
-- workspace | <one row per record published>
```

Publish the same batch again and you get one new alert, because it is a new stream sequence. If the
same message is redelivered, no new row appears. The S3 archive gets its objects within 5 minutes
(`storage.s3.flushInterval`).

### Go live with Workspace

On AWS the ingester federates its Lambda role into Google, with no key at all. A cluster has no
such identity, so on Kubernetes the ingester uses a service-account key instead:

1. Create a key for a service account that may impersonate the delegated service account
   (`roles/iam.serviceAccountTokenCreator`). The delegated service account and the Workspace
   subject are set up exactly as for AWS (chapter 7, and the ingester README, "Credential setup").
2. Store it:

   ```bash
   kubectl -n samma-siem create secret generic ingester-google --from-file=key.json=<key file>
   ```

3. Add the subject and the service account to your values and set one replica. The chart refuses
   `replicas: 1` without them, and more than one replica.

   ```yaml
   ingester:
     perSource:
       google-workspace:
         replicas: 1
         env:
           INGESTER_GWS_SUBJECT: reports-reader@example.com
           INGESTER_GCP_TARGET_SERVICE_ACCOUNT: delegated@my-project.iam.gserviceaccount.com
   ```

4. Run `helm upgrade` again.

The first pass reads the last hour of every Admin Reports application. Watch it with
`nats consumer info INGESTER_SLICES ingester-google-workspace`, and see each partition's progress in
the `ingester_checkpoint` table.

## Add a Sigma rule

Rules live in the [detection-engine](https://github.com/samma-io/detection-engine) repo, one
directory per lane, and are baked into the image. A new rule is a new image.

```
rules/<lane>/sigma-config.yml     field mappings for the lane
rules/<lane>/<rule>.yml           a Sigma rule
rules/<lane>/<rule>.tests.yml     REQUIRED: cases proving the rule fires, and does not
```

1. **Write the rule** against the fields Vector actually emits. For `workspace` the event is at the
   root (`name`, `type`), with the envelope's `source` and `feed`:

   ```yaml
   # rules/workspace/suspicious_login.yml
   title: Google Workspace Suspicious Login
   id: 6f1c2d3e-4a5b-4c6d-8e7f-9a0b1c2d3e4f   # a new UUID; the alert id is derived from it
   status: experimental
   description: Google flagged a sign-in as suspicious.
   references:
     - https://developers.google.com/admin-sdk/reports/v1/appendix/activity/login
   author: samma-io
   level: high
   tags:
     - attack.initial_access
   logsource:
     product: workspace
     service: reports
   detection:
     selection:
       source: workspace
       feed: login
       name:
         - suspicious_login
         - suspicious_login_less_secure_app
         - suspicious_programmatic_login
     condition: selection
   falsepositives:
     - A user travelling or signing in from a new device.
   ```

2. **Write the test cases** from a real record: at least one `expected: true` case, and the near
   misses that must not fire. Every event carries `source: <lane>`.

   ```yaml
   # rules/workspace/suspicious_login.tests.yml
   - name: a suspicious login fires
     expected: true
     event:
       source: workspace
       feed: login
       actor_email: example.person@example.com
       type: login
       name: suspicious_login

   - name: an ordinary login does not fire
     expected: false
     event:
       source: workspace
       feed: login
       actor_email: example.person@example.com
       type: login
       name: login_success
   ```

3. **Run the gate.** `make docs` regenerates the rule catalogue (`docs/RULES.md`), and
   `make rulecheck` fails while it is stale. Both run in a Go container, so you need Docker only.
   The repo needs Go 1.26, but the Makefile's default image is still `golang:1.25`, so pass the
   image:

   ```bash
   make docs GO_IMAGE=golang:1.26
   make rulecheck GO_IMAGE=golang:1.26
   ```

   The gate compiles every lane as the engine does at start and runs every test case. It rejects a
   rule without a firing case, a `*` or `?` in a value (sigma-go matches them literally, so the rule
   never fires), and a rule that fires on the same test event as another one. Also read
   `rules/README.md` for what the engine cannot express: aggregations, `timeframe`, correlation and
   `keywords`.

4. **Build the image and deploy it.** Open a pull request. Once it is merged, build and push the
   image from `main`, tagged with the short git sha:

   ```bash
   echo "$GHCR_TOKEN" | docker login ghcr.io -u <github-user> --password-stdin
   make image push
   git rev-parse --short HEAD   # the new detectionEngine.tag
   ```

   ```bash
   helm upgrade --install samma-siem chart/samma-siem -n samma-siem -f siem-values.yaml \
     --set detectionEngine.tag=<short sha>
   ```

   Or put the tag in your values file. Check that the rule is loaded:

   ```bash
   kubectl -n samma-siem port-forward svc/samma-siem-detection-engine-workspace 9090:9090
   curl -s http://localhost:9090/rules
   ```

## Configure the routes

alert-destination decides where each alert goes from a routing table. Matching is most specific
first on `(level, log_source)`: an exact pair beats an exact level with any source, which beats
any level with an exact source, which beats `"*"`/`"*"`. Every table needs a `default`.

The chart's default table sends everything to Postgres:

```yaml
require_slack: false
routes:
  - {level: "*", log_source: "*", deliveries: [{to: postgres, target: siem_alerts}]}
default:
  deliveries: [{to: postgres, target: siem_alerts}]
```

To replace it, set `alertDestination.routes` to a whole table. The chart puts it in the ConfigMap
`samma-siem-alert-routes`, and an upgrade restarts alert-destination with it:

```yaml
# routes.yaml
alertDestination:
  routes: |
    require_slack: false
    routes:
      - {level: critical, log_source: "*", deliveries: [{to: postgres, target: siem_alerts}]}
      - {level: "*", log_source: "*", deliveries: [{to: postgres, target: siem_alerts}]}
    default:
      deliveries: [{to: postgres, target: siem_alerts}]
```

**Slack and GitHub do not work on Kubernetes yet.** The NATS transport of alert-destination builds
only the `postgres` destination, in the image the chart runs (`779befa`) and on `main`. A table that
names `slack` or `github` makes it fail at start. `require_slack: false` must be written out, so
the table says plainly that nothing pages a human.

When an image with Slack and GitHub in its NATS transport exists, the chart is ready for it: set
`alertDestination.slack.enabled: true` (that is `require_slack`), a table where every route
includes Slack, and `alertDestination.existingSecret` for the Secret with the tokens. Tokens never
go in values. The routing rules are in the alert-destination README, "Routing table".

## Reach Grafana and Quickwit

Neither has an Ingress or a hostname. Use `kubectl port-forward`:

```bash
kubectl -n samma-siem port-forward svc/samma-siem-grafana 3000:3000
# http://localhost:3000, user admin, the admin-password from the siem-grafana Secret

kubectl -n samma-siem port-forward svc/samma-siem-quickwit 7280:7280
# http://localhost:7280/ui/search, and the REST API under /api/v1
```

Read the Grafana password with:

```bash
kubectl -n samma-siem get secret siem-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

The **SIEM alerts** dashboard reads `siem_alerts`: alerts by level, over time, by lane, top rules
and the latest alerts. The Quickwit dashboards stay empty for now, because nothing writes to
Quickwit yet in Kubernetes (see below).

## Where the data lives

| What | Where | Written by | Kept |
|---|---|---|---|
| Raw vendor records | stream `SIEM_RAW` | ingester | 24h |
| Filtered records | stream `SIEM_LOGS` | Vector | 7 days |
| Alerts | stream `SIEM_ALERTS` | detection-engine | 30 days |
| Filtered records | table `siem_events` | siem-storage | 30 days (`storage.eventsRetention`) |
| Alerts | table `siem_alerts` | alert-destination | no expiry |
| Delivery ledger | table `alert_ledger` | alert-destination | per row, `expires_at` |
| Ingester watermarks | table `ingester_checkpoint` | ingester | one row per partition |
| Archive of records and alerts | S3, see below | siem-storage | your bucket's lifecycle |
| Search index | `s3://<bucket>/quickwit/indexes`, metastore in the `quickwit` database | Quickwit | derived; rebuilt from the streams |

**`siem_events`** is a TimescaleDB hypertable with one row per record: `time` (the record's own
event time), `lane`, `subject`, `stream_seq`, `line` and the whole record in `record jsonb`.

**`siem_alerts`** has one row per alert id, with `alerted_at`, `log_source`, `rule_id`,
`rule_title`, `level`, `provenance` and the whole `detection.alert.v1` document in `alert jsonb`.

**The S3 archive** has the same layout as the AWS filtered bucket, so a reader that understands the
AWS layout reads it unchanged:

```
s3://samma-siem-archive/<lane>/date=YYYY-MM-DD/<ts>-storage-s3-logs-<firstseq>.log.gz
    gzip NDJSON, one filtered record per line; date and ts are the UTC flush time

s3://samma-siem-archive/alerts/log_source=<lane>/date=YYYY-MM-DD/<alert id>.json
    one alert per object; date is alerted_at in UTC
```

To look at it in the bundled MinIO, port-forward it and use any S3 client with the root
credentials:

```bash
kubectl -n samma-siem port-forward svc/samma-siem-minio 9000:9000
export AWS_ACCESS_KEY_ID=$(kubectl -n samma-siem get secret samma-siem-minio -o jsonpath='{.data.rootUser}' | base64 -d)
export AWS_SECRET_ACCESS_KEY=$(kubectl -n samma-siem get secret samma-siem-minio -o jsonpath='{.data.rootPassword}' | base64 -d)
aws --endpoint-url http://localhost:9000 s3 ls s3://samma-siem-archive/ --recursive
```

**`scan_results` is not part of the SIEM.** It is the scanner's table, written by the bridge from
NATS into the scanner's database (chapter 1). The SIEM role has no grant on it, and siem-storage
never touches it.

## What is not on Kubernetes yet

- **The `k8s` and `scanner` lanes.** Their rules are in detection-engine `main`, but no published
  image has them: build one from `0c5b5ce` or later. Nothing publishes to their subjects yet
  either. The `k8s` lane needs a shipper that publishes one Kubernetes audit event per message to
  `samma.logs.k8s`. The `scanner` lane needs a relay from the scanners' `samma-io.scan` subjects to
  `samma.logs.scanner`. Until then, anything that can publish NDJSON to `samma.logs.<lane>` can feed
  a lane.
- **Ingest for lanes other than Workspace.** The Slack, 1Password and Cloudflare pullers still read
  their tokens from AWS SSM. Vector's Kubernetes configuration reads only the Workspace lane, so
  another raw lane needs a Vector image whose configuration reads it.
- **Slack and GitHub alerts.** Alerts go to Postgres only, as described in
  [Configure the routes](#configure-the-routes).
- **Published Quickwit and Grafana images.** You build them yourself.
- **Data in Quickwit.** Quickwit and its indexes come up, but Vector's Kubernetes configuration
  does not send anything to Quickwit's ingest API yet, so search is empty.

There is no Elasticsearch or Loki in this SIEM. The original Kubernetes SIEM, with its own YAML
rule engine, is being retired (samma-io/siem#4). It is described in
[the legacy chapter](../legacy/8-kubernetes-siem-custom-engine/README.md) only for reference.

## Next steps

- The chart's own reference, with every value: `chart/samma-siem/README.md` in the
  [siem](https://github.com/samma-io/siem) repo.
- How the lanes and rules work: [6. AWS SIEM: how the data flows](../6-aws-siem-data-flow/README.md).
- Running the same SIEM on AWS: [7. Deploy your own AWS SIEM](../7-aws-siem-deploy/README.md).
- Back to the [guide index](../README.md).
