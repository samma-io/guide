# 8. The SIEM on Kubernetes

The SIEM from chapters 6 and 7 also runs inside a Kubernetes cluster. It uses the same images, the
same Sigma rules and the same alert format. Only the plumbing changes: on AWS the services talk
through S3 and SQS, and in Kubernetes they talk through **NATS JetStream**, with alerts stored in
**PostgreSQL**.

This chapter shows how the pieces connect, how to deploy them, and how to prove the whole path
works with one test event.

## What you will learn

- How a log record becomes an alert row in Postgres over NATS.
- Which streams, subjects and consumers the services expect.
- How to deploy the core (detection and alerts) and run a smoke test.
- How ingest works: the ingester and Vector, and what the ingester needs to go live.
- What is not on Kubernetes yet.

## How the data flows

```
 ingester                    Vector                      detection-engine            alert-destination
 one per SaaS source         one per lane                one per lane                one
      │                          │                            │                           │
      ▼                          ▼                            ▼                           ▼
 samma.raw.<lane> ─► SIEM_RAW ─► envelope VRL ─► SIEM_LOGS ─► Sigma rules ─► SIEM_ALERTS ─► Postgres
 vendor records                  samma.logs.<lane>             samma.alerts.<lane>         siem_alerts
```

1. **Pull.** The ingester reads a SaaS audit API (for Google Workspace, the Admin Reports API) in
   time slices. It publishes one vendor-native record per message on `samma.raw.<lane>`, keyed by
   the record's dedupe key. Its slice queue is the stream `INGESTER_SLICES`, and it keeps its
   watermarks in Postgres (`ingester_checkpoint`).
2. **Normalise.** Vector reads `samma.raw.<lane>` from the durable consumer `vector-<lane>`, adds
   the envelope every lane shares (`source`, `feed`, `event_time`, `actor_email`, `search_text`),
   and publishes the filtered record on `samma.logs.<lane>`. It is the same VRL the AWS pipeline
   runs. It acks the raw message only once the filtered record is stored.
3. **Detect.** `detection-engine` with `ENGINE_TRANSPORT=nats` pulls from the durable consumer
   `detection-engine-<lane>` and runs that lane's Sigma rules on every record. It publishes each match
   to `samma.alerts.<lane>`, and only then acks the log message.
4. **Store.** `alert-destination` with `ALERTDEST_TRANSPORT=nats` pulls from the consumer
   `alert-destination`, routes each alert, and inserts it into the `siem_alerts` table. It acks the
   alert only after the row is written.

**Duplicates are safe at every step.**
- A raw record re-read by a reconcile pass carries the same dedupe key, and `SIEM_RAW` drops it
  inside its 2-hour duplicate window.
- An alert's id comes from the rule and the record's position in the stream (`nats:SIEM_LOGS`,
  `<subject>/<sequence>`). A redelivered message therefore produces the same id.
- JetStream drops a republished alert inside its 2-minute duplicate window.
- The table has one row per id.

**What happens on failure.** A message that keeps failing is redelivered up to 5 times
(`MaxDeliver`) and then left in the stream. That is the NATS equivalent of the SQS dead-letter queue.

The full contract is in the `aws-siem` repo at `docs/contracts/detection-alert-v1.md`, section
"NATS transport".

## The streams

| Stream | Subjects | Kept for | Consumer(s) |
|---|---|---|---|
| `INGESTER_SLICES` | `samma.ingester.slices.<source>` | work queue, 24h | `ingester-<source>`: AckWait 20m, MaxDeliver 5 |
| `SIEM_RAW` | `samma.raw.<lane>`, one per lane you deploy | 24h, byte-capped | `vector-<lane>`: AckWait 60s, MaxDeliver 5 |
| `SIEM_LOGS` | `samma.logs.<lane>`, one per lane you deploy | 7 days, byte-capped | `detection-engine-<lane>`: AckWait 300s, MaxDeliver 5 |
| `SIEM_ALERTS` | `samma.alerts.>` | 30 days, byte-capped | `alert-destination`: AckWait 120s, MaxDeliver 5 |

The deployment creates the consumers, not the services. detection-engine refuses to start if its
consumer filters a different subject than its lane. That stops one lane's rules from running on
another lane's events.

List lanes explicitly in `SIEM_RAW` and `SIEM_LOGS` rather than capturing `samma.logs.>`. Older Samma components
publish high-volume cluster logs under `samma.logs.k8s*`, and capturing them fills the stream in
minutes.

## Deploy the core

You need:
- a cluster with a JetStream-enabled NATS
- a PostgreSQL you can create a database on
- an amd64 node, because the images are linux/amd64

The manifests the Samma team runs are in the `deploy` repo under `siem/`. The steps below use them.

1. **A database and role.** Give the SIEM its own `siem` database and role, so it cannot touch
   scanner data. Keep the role's password and DSN in a Secret:

   ```bash
   PW=$(openssl rand -hex 24)
   kubectl -n samma create secret generic siem-postgres \
     --from-literal=password="$PW" \
     --from-literal=dsn="postgres://siem:$PW@<postgres-host>:5432/siem?sslmode=disable"
   unset PW
   ```

2. **Streams, consumers and the database.** These are two idempotent Jobs:

   ```bash
   kubectl apply -f siem/00-streams-job.yaml -f siem/01-db-init-job.yaml
   kubectl -n samma wait --for=condition=complete job/siem-streams job/siem-db-init
   ```

3. **The services.** `alert-destination` creates its tables (`siem_alerts`, `alert_ledger`) when it
   starts, and the ingester creates `ingester_checkpoint`:

   ```bash
   kubectl apply -f siem/10-detection-engine-workspace.yaml -f siem/20-alert-destination.yaml \
                 -f siem/30-siem-vector-workspace.yaml -f siem/40-ingester-workspace.yaml
   ```

   The ingester ships at `replicas: 0`. It needs a Google credential first; see
   [Going live with Workspace](#going-live-with-workspace).

The settings that matter:

| Service | Variable | Value |
|---|---|---|
| detection-engine | `ENGINE_TRANSPORT` | `nats` |
| | `ENGINE_LOG_SOURCE` | the lane, for example `workspace` |
| | `ENGINE_NATS_URL` | `nats://nats.samma.svc:4222` |
| | `ENGINE_RULES_DIR` | `/rules`, the rules baked into the image |
| Vector | `--config` | `/etc/vector/vector-k8s.yaml`, baked into the image |
| | `NATS_URL` | `nats://nats.samma.svc:4222` |
| ingester | `INGESTER_TRANSPORT` | `nats` |
| | `INGESTER_SOURCE` | `google-workspace` |
| | `INGESTER_NATS_URL` | `nats://nats.samma.svc:4222` |
| | `INGESTER_POSTGRES_DSN_FILE` | the mounted `dsn` key of `siem-postgres` |
| | `GOOGLE_APPLICATION_CREDENTIALS` | the mounted service-account key |
| alert-destination | `ALERTDEST_TRANSPORT` | `nats` |
| | `ALERTDEST_NATS_URL` | `nats://nats.samma.svc:4222` |
| | `ALERTDEST_POSTGRES_DSN_FILE` | the mounted `dsn` key of `siem-postgres` |
| | `ALERTDEST_ROUTES_PATH` | the routing table, mounted from a ConfigMap |

The routing table sends everything to Postgres:

```yaml
require_slack: false          # say it out loud: nothing pages a human yet
routes:
  - {level: "*", log_source: "*", deliveries: [{to: postgres, target: siem_alerts}]}
default:
  deliveries: [{to: postgres, target: siem_alerts}]
```

## Smoke test with Google Workspace

The `workspace` lane ships two critical rules: "Admin Role Granted" and "Two-Step Verification
Disabled".

### The whole path, from raw records

Publish two raw Admin Reports activities, shaped exactly as the ingester writes them. The first
should fire and the second should not:

```bash
for n in ASSIGN_ROLE UNASSIGN_ROLE; do
  kubectl -n samma exec deploy/nats-box -- nats pub samma.raw.workspace \
    "{\"kind\":\"admin#reports#activity\",\"id\":{\"time\":\"$(date -u +%FT%TZ)\",\"applicationName\":\"admin\"},\"actor\":{\"email\":\"smoke@example.com\"},\"type\":\"DELEGATED_ADMIN_SETTINGS\",\"name\":\"$n\"}" \
    -H "Nats-Msg-Id:smoke-$n-$(date +%s)"
done
```

Vector turns each one into a filtered record on `samma.logs.workspace`, with `feed` set to `admin`
and `actor_email` set to `smoke@example.com`. From there it continues as below. Publishing the
same `Nats-Msg-Id` again within two hours is dropped by `SIEM_RAW`.

### Detection only, from filtered records

Publish one record that should fire and one that should not:

```bash
kubectl -n samma exec deploy/nats-box -- nats pub samma.logs.workspace \
'{"source":"workspace","feed":"admin","actor_email":"smoke@example.com","type":"DELEGATED_ADMIN_SETTINGS","name":"ASSIGN_ROLE"}
{"source":"workspace","feed":"admin","actor_email":"smoke@example.com","type":"DELEGATED_ADMIN_SETTINGS","name":"UNASSIGN_ROLE"}'
```

Here is what you should see:

```bash
kubectl -n samma logs deploy/detection-engine-workspace --tail=1
# "object complete" ... "events":2 ... "matched":1,"published":1

kubectl -n samma logs deploy/alert-destination --tail=2
# "routing decided" ... "destinations":["postgres:siem_alerts"]
```

```sql
-- in the siem database
SELECT alerted_at, level, rule_title, provenance->>'key' AS key
FROM siem_alerts ORDER BY alerted_at DESC LIMIT 5;
-- critical | Google Workspace Admin Role Granted | samma.logs.workspace/<seq>
```

Publish the same batch again and you get one new row, because it is a new stream sequence. If the
same message is redelivered, no new row appears.

## Going live with Workspace

On AWS the ingester federates its Lambda role into Google, with no key at all. A cluster has no
such identity, so on Kubernetes the ingester uses a service-account key instead:

1. Create a key for a service account that may impersonate the delegated service account
   (`roles/iam.serviceAccountTokenCreator`). The delegated service account and the Workspace
   subject are set up exactly as for AWS (chapter 7).
2. Store it: `kubectl -n samma create secret generic ingester-google --from-file=key.json=<key>`.
3. Set `INGESTER_GWS_SUBJECT` and `INGESTER_GCP_TARGET_SERVICE_ACCOUNT` in
   `siem/40-ingester-workspace.yaml`, apply it, and scale it to one replica.

The first pass reads the last hour of every Admin Reports application. Watch it with
`nats consumer info INGESTER_SLICES ingester-google-workspace`, and see each partition's progress
in the `ingester_checkpoint` table.

## Adding a lane

Every lane from chapter 6 has rules in the image: `aws`, `github`, `dns`, `alb`, `slack`,
`onepassword`, `workspace`, `gcp` and `cloudflare`. To add detection for one:

1. Add `samma.logs.<lane>` to the `SIEM_LOGS` subjects in the streams Job.
2. Add the `detection-engine-<lane>` consumer in the same Job.
3. Copy the workspace Deployment and set `ENGINE_LOG_SOURCE=<lane>`.

Ingest for a new lane also needs its VRL in Vector's `vector-k8s.yaml` and a `SIEM_RAW` subject
with a `vector-<lane>` consumer.

## What is not on Kubernetes yet

- **Ingest for lanes other than Workspace.** The Slack, 1Password and Cloudflare pullers still
  read their tokens from AWS SSM, and Vector's Kubernetes configuration carries only the Workspace
  lane. Until then, anything that can publish NDJSON to `samma.logs.<lane>` can feed a lane.
- **Slack and GitHub alerts, and the S3 alert archive.** In Kubernetes, alerts go to Postgres only for
  now.
- **Quickwit search and the Grafana dashboards.**
- **A Kubernetes audit-log lane, and scanner findings as a lane.**

The original Kubernetes SIEM, the YAML rule engine in `siem`, is described in
[the legacy chapter](../legacy/8-kubernetes-siem-custom-engine/README.md).

## Next steps

- How the lanes and rules work: [6. AWS SIEM: how the data flows](../6-aws-siem-data-flow/README.md).
- Running the same SIEM on AWS: [7. Deploy your own AWS SIEM](../7-aws-siem-deploy/README.md).
- Back to the [guide index](../README.md).
