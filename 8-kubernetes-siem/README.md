# 8. The SIEM on Kubernetes

The SIEM from chapters 6 and 7 also runs inside a Kubernetes cluster. It uses the same images, the
same Sigma rules and the same alert format. Only the plumbing changes: on AWS the services talk
through S3 and SQS, and in Kubernetes they talk through **NATS JetStream**, with alerts stored in
**PostgreSQL**.

This chapter shows how the pieces connect, how to deploy the core, and how to prove it works with
one test event.

## What you will learn

- How a log record becomes an alert row in Postgres over NATS.
- Which streams, subjects and consumers the services expect.
- How to deploy the core (detection and alerts) and run a smoke test.
- What is not on Kubernetes yet.

## How the data flows

```
 ingester / Vector                detection-engine                 alert-destination
 (next step)                      one Deployment per lane          one Deployment
      │                                  │                                │
      ▼                                  ▼                                ▼
 samma.logs.<lane>  ──►  SIEM_LOGS  ──►  Sigma rules  ──►  samma.alerts.<lane>  ──►  SIEM_ALERTS  ──►  Postgres
 NDJSON records          (stream)        for the lane      detection.alert.v1         (stream)          siem_alerts
```

1. **Publish.** A producer publishes filtered records as NDJSON on `samma.logs.<lane>`, for example
   `samma.logs.workspace`. One message can hold one record or a batch.
2. **Detect.** `detection-engine` with `ENGINE_TRANSPORT=nats` pulls from the durable consumer
   `detection-engine-<lane>` and runs that lane's Sigma rules on every record. It publishes each match
   to `samma.alerts.<lane>`, and only then acks the log message.
3. **Store.** `alert-destination` with `ALERTDEST_TRANSPORT=nats` pulls from the consumer
   `alert-destination`, routes each alert, and inserts it into the `siem_alerts` table. It acks the
   alert only after the row is written.

**Duplicates are safe at every step.**
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
| `SIEM_LOGS` | `samma.logs.<lane>`, one per lane you deploy | 7 days, byte-capped | `detection-engine-<lane>`: AckWait 300s, MaxDeliver 5 |
| `SIEM_ALERTS` | `samma.alerts.>` | 30 days, byte-capped | `alert-destination`: AckWait 120s, MaxDeliver 5 |

The deployment creates the consumers, not the services. detection-engine refuses to start if its
consumer filters a different subject than its lane. That stops one lane's rules from running on
another lane's events.

List lanes explicitly in `SIEM_LOGS` rather than capturing `samma.logs.>`. Older Samma components
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
   starts:

   ```bash
   kubectl apply -f siem/10-detection-engine-workspace.yaml -f siem/20-alert-destination.yaml
   ```

The settings that matter:

| Service | Variable | Value |
|---|---|---|
| detection-engine | `ENGINE_TRANSPORT` | `nats` |
| | `ENGINE_LOG_SOURCE` | the lane, for example `workspace` |
| | `ENGINE_NATS_URL` | `nats://nats.samma.svc:4222` |
| | `ENGINE_RULES_DIR` | `/rules`, the rules baked into the image |
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
Disabled". Publish one record that should fire and one that should not:

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

## Adding a lane

Every lane from chapter 6 has rules in the image: `aws`, `github`, `dns`, `alb`, `slack`,
`onepassword`, `workspace`, `gcp` and `cloudflare`. To add one:

1. Add `samma.logs.<lane>` to the `SIEM_LOGS` subjects in the streams Job.
2. Add the `detection-engine-<lane>` consumer in the same Job.
3. Copy the workspace Deployment and set `ENGINE_LOG_SOURCE=<lane>`.

## What is not on Kubernetes yet

- **Ingest.** On AWS, the ingester pulls SaaS audit logs and Vector filters them. Both still write to
  S3. Their NATS mode, publishing to `samma.logs.<lane>`, is the next step. Until then, anything that
  can publish NDJSON to NATS can feed a lane.
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
