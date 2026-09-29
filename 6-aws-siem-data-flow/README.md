# 6. AWS SIEM: how the data flows

This chapter follows one log record through the Samma AWS SIEM. It starts where the record is
created, in AWS, GitHub or a SaaS tool. It ends when the record is searchable in Grafana and
Quickwit, or, if a rule matches, when it has become an alert in Slack and GitHub.

[Chapter 7](../7-aws-siem-deploy/README.md) shows how to deploy all of this into your own AWS account.

> The AWS SIEM and the scanner (chapters 1–5) are separate systems today: scanner findings go to
> TimescaleDB and the Samma dashboard, not into the SIEM.

## What you will learn

- The two ways data enters the SIEM: **pushed** by AWS and GitHub, or **pulled** by the ingester.
- How an S3 bucket plus an SQS queue hands logs to Vector.
- What a *lane* is, and why nearly everything is per lane.
- How detection runs, and which SQS queues it needs.
- How an alert reaches Slack and GitHub.
- How the same data reaches Quickwit, Athena and Grafana.

## The repositories

| Repo | What it does in the flow |
|---|---|
| [`aws-siem`](https://github.com/samma-io/aws-siem) | Terraform that creates every bucket, queue, service and Lambda below |
| [`ingester`](https://github.com/samma-io/ingester) | Pulls SaaS audit logs (Slack, 1Password, Google Workspace, Cloudflare, GCP) into S3 |
| [`vector`](https://github.com/samma-io/vector) | Reads raw logs, parses, filters and normalises them, writes per-lane files |
| [`detection-engine`](https://github.com/samma-io/detection-engine) | Runs Sigma rules on every record, one service per lane |
| [`alert-destination`](https://github.com/samma-io/alert-destination) | Archives each alert, then sends it to Slack and GitHub issues |
| [`quickwit`](https://github.com/samma-io/quickwit) | Full-text search over the last 90 days |
| [`grafana`](https://github.com/samma-io/grafana) | Dashboards over Quickwit and Athena |

---

## The whole picture

```
                     ┌──────────────────────── 1. INGEST ─────────────────────────┐
 AWS / GitHub  ────► │ raw S3 bucket ──(ObjectCreated)──► raw SQS queue            │
 (push to S3)        │   <p>-<source>-<acct>-<region>     <p>-raw-<source>         │
                     │                                                             │
 SaaS APIs     ────► │ ingester Lambda ──► raw S3 bucket ──► raw SQS queue         │
 (pulled)            └───────────────────────────────┬─────────────────────────────┘
                                                     ▼
                     ┌──────────────────────── 2. PARSE ──────────────────────────┐
                     │ Vector (ECS): parse · allowlist · drop noise · envelope     │
                     │   writes  s3://<p>-filtered-…/<lane>/date=YYYY-MM-DD/*.gz   │
                     └───────┬───────────────────────┬──────────────────┬─────────┘
                S3 notification per lane      EventBridge          Glue table per lane
                             ▼                       ▼                  ▼
            ┌──── 3. DETECT ────────┐   ┌── 5. SEARCH ─────────┐  ┌── Athena ───────┐
            │ <p>-filtered-<lane>   │   │ <p>-quickwit-<index> │  │ <p>_security_   │
            │ detection-engine      │   │ Quickwit (ECS)       │  │ logs workgroup  │
            │ (1 ECS service/lane)  │   └──────────┬───────────┘  └────────┬────────┘
            └──────────┬────────────┘              └──────► Grafana ◄──────┘
                       ▼                                 (behind ALB + OIDC login)
            ┌──── 4. ALERT ─────────────────────────────┐
            │ <p>-detections-alerts (SQS)               │
            │ alert-destination (Lambda)                │
            │   ├─► archive: s3://<p>-detections-…/alerts/…
            │   ├─► Slack channel                       │
            │   └─► GitHub issue                        │
            └───────────────────────────────────────────┘
```

`<p>` is your `name_prefix`, which defaults to `siem`.

**One rule holds throughout: SQS never carries a log.** Every queue message is a small S3 event that
says "a new object exists at bucket/key". Each consumer fetches the object itself. This keeps the
queues cheap. It also means you can always re-drive processing from S3.

---

## Lanes

A **lane** is one family of logs. Each lane gets its own filtered-bucket folder, queue, detection
service, rules folder and Athena table.

| Lane | What is in it | Where it comes from |
|---|---|---|
| `aws` | CloudTrail, S3 access logs, ALB access logs, VPC flow logs, SSO Elevator | pushed |
| `github` | GitHub organisation audit log | pushed (GitHub streams to S3) |
| `dns` | Route 53 Resolver query logs | pushed |
| `alb` | ALB *connection* logs (TLS details) | pushed |
| `slack` | Slack access and integration logs | pulled by the ingester |
| `onepassword` | 1Password item usage, sign-ins, audit events | pulled by the ingester |
| `workspace` | Google Workspace Admin Reports | pulled by the ingester |
| `cloudflare` | Cloudflare audit, Access, devices, firewall, Gateway | pulled by the ingester |
| `gcp` | GCP Cloud Audit Logs | forwarded from Pub/Sub by the ingester |

The lane name is used verbatim everywhere: the folder `<lane>/`, the field `source: <lane>`, the queue
`<p>-filtered-<lane>`, the rules folder `rules/<lane>/` and the Athena table `filtered_<lane>`.

---

## 1a. Ingest by push: bucket → SQS → Vector

This is the path for AWS logs and GitHub. The producer writes files into a bucket. S3 announces each
new file to a queue, and Vector reads the queue.

```
 producer ──PutObject──► s3://<p>-<source>-<acct>-<region>/AWSLogs/<acct>/…
                                   │  S3 event notification (ObjectCreated, prefix/suffix filter)
                                   ▼
                          SQS <p>-raw-<source>  (14-day retention, DLQ after 5 tries)
                                   │  long poll
                                   ▼
                               Vector
```

The raw buckets and queues Terraform creates:

| Source | Bucket | Raw queue | Vector env var |
|---|---|---|---|
| CloudTrail | `<p>-cloudtrail-…` | `<p>-raw-cloudtrail` | `QUEUE_URL_CLOUDTRAIL` |
| S3 server access logs | `<p>-s3-access-…` | `<p>-raw-s3-access` | `QUEUE_URL_S3ACCESS` |
| VPC flow logs | `<p>-vpcflow-…` | `<p>-raw-vpcflow` | `QUEUE_URL_VPCFLOW` |
| Route 53 Resolver | `<p>-dns-…` | `<p>-raw-dns` | `QUEUE_URL_DNS` |
| ALB access and connection logs | `<p>-alb-…` | `<p>-raw-alb` | `QUEUE_URL_ALB` |
| SSO Elevator audit | `<p>-sso-elevator-…` | `<p>-raw-sso-elevator` | `QUEUE_URL_SSO` |
| GitHub audit log | `<p>-github-audit-…` | `<p>-raw-github-audit` | `QUEUE_URL_GITHUB` |

### How the S3 → SQS link works

S3 can send an event to an SQS queue every time an object is created. Terraform sets up both parts:

1. A **bucket notification** on the bucket, which says "send `s3:ObjectCreated:*` for keys that start
   with `AWSLogs/` and end with `.log.gz` to this queue". The prefix and suffix filters keep S3's own
   test files and folder markers out.
2. A **queue policy** on the queue, which lets `s3.amazonaws.com` send messages, but only from that
   bucket and only from your account.

You can do the same by hand for any bucket. This is what the `sources/*` modules do:

```sh
aws s3api put-bucket-notification-configuration --bucket <bucket> --notification-configuration '{
  "QueueConfigurations": [{
    "QueueArn": "arn:aws:sqs:<region>:<acct>:<p>-raw-vpcflow",
    "Events": ["s3:ObjectCreated:*"],
    "Filter": {"Key": {"FilterRules": [
      {"Name": "prefix", "Value": "AWSLogs/"},
      {"Name": "suffix", "Value": ".log.gz"}]}}
  }]}'
```

Things that trip people up:

- **A bucket has exactly one notification configuration.** `put-bucket-notification-configuration`
  replaces the whole configuration. Adding a queue to a bucket that already notifies something else
  means merging the two by hand.
- **Never put `=` in a prefix filter.** S3 URL-encodes keys in events (`date=` becomes `date%3D`), so
  a prefix containing `=` never matches. That is why the filtered bucket uses `<lane>/date=…` and not
  `lane=<lane>/…`.
- **The bucket, the queue and Vector must be in the same region.**

### What Vector does with it

Vector (`vector/config/vector.yaml`) runs its `aws_s3` sources in **SQS mode**. It receives a
message, downloads the object, splits it into lines, then:

1. **Routes by content.** The s3-access, vpcflow, dns and alb queues all feed one router
   (`route_s3access`). It recognises VPC flow rows, ALB connection logs and Resolver JSON by their
   shape. It does not matter which bucket a log arrived in.
2. **Parses** each format (CloudTrail JSON, flow-log columns, ALB and S3 access formats, and so on).
3. **Drops what you do not want:**
   - every record from an AWS account that is **not on `account_allowlist`** (fail closed);
   - AWS-service and service-linked-role noise, and principals listed in `noise_principals.csv`;
   - Resolver lookups of `amazonaws.com` names.
4. **Normalises.** Every `aws` record gets an `eventTime`. Every SaaS record gets the envelope
   `source`, `feed`, `event_time`, `actor_email` and `search_text`.
5. **Writes** gzip NDJSON to the **filtered bucket**, at
   `s3://<p>-filtered-<acct>-<region>/<lane>/date=YYYY-MM-DD/<file>.gz`. It flushes every 5 minutes.

Everything that was dropped is still in the raw bucket, which is kept for 6 years by default, and you
can still query it through Athena.

---

## 1b. Ingest by pull: the ingester

SaaS tools do not write to S3, so the **ingester** asks their APIs for new events and writes them
to S3. From S3 onward the path is exactly the one above.

```
 EventBridge ─(every 10 min)─► schedule Lambda ──┐
 EventBridge ─(every hour)───► reconcile Lambda ─┤  plan time windows ("slices") per partition
                                                 ▼
                          SQS <p>-ingester-<lane>-slices  (+ -slices-dlq)
                                                 │  one slice per invocation
                                                 ▼
 SSM token ───────────────────────────────► worker Lambda ──► vendor API (Slack, 1Password, …)
 DynamoDB <p>-ingester-<lane>-checkpoint ◄──────┤ watermarks, leases
                                                 ▼
                s3://<p>-<saas>-<acct>-<region>/<prefix><partition>/YYYY/MM/DD/*.ndjson.gz
                                                 │  S3 notification
                                                 ▼
                          SQS <p>-raw-<saas>  ──►  Vector  ──►  filtered/<lane>/…
```

How one run works:

1. **Schedule** (every 10 minutes) reads the **watermark** of each partition from DynamoDB, for
   example Slack `access` and `integrations`, or 38 Google Workspace applications. It then queues a
   *slice* such as "slack/access from 10:00 to 10:08" on the slice queue.
2. **Reconcile** (hourly) re-queues a trailing window, to catch events the vendor publishes late.
3. **Worker** receives one slice and takes a short **lease** on that partition, so two workers never
   read the same partition at once. It reads the vendor API page by page, writes gzip NDJSON to the
   raw bucket, and then moves the watermark forward. If anything fails, the watermark stays put and
   the lease is released, so SQS retries the slice.
4. **Backfill** (off by default) walks backwards through history, one chunk per run, as far as the
   vendor keeps data.

Each SaaS source gets its own raw bucket and queue from the `sources/saas` module:

| Ingester lane | Writes to prefix | Raw queue | Vector env var | Lane |
|---|---|---|---|---|
| `slack` | `slack/` | `<p>-raw-slack` | `QUEUE_URL_SLACK` | `slack` |
| `onepassword` | `onepassword/` | `<p>-raw-onepassword` | `QUEUE_URL_ONEPASSWORD` | `onepassword` |
| `google-workspace` | `activities/` | `<p>-raw-workspace` | `QUEUE_URL_WORKSPACE` | `workspace` |
| `cloudflare` | `cloudflare/` | `<p>-raw-cloudflare` | `QUEUE_URL_CLOUDFLARE` | `cloudflare` |
| `gcp-forward` | `logs/` | `<p>-raw-gcp` | `QUEUE_URL_GCP` | `gcp` |

`gcp-forward` is different: GCP pushes audit logs to a Pub/Sub subscription, and a single Lambda
drains it every minute.

**Credentials.**
- Slack, 1Password and Cloudflare tokens are read from **SSM Parameter Store** at
  `/<p>/ingester/<lane>/<NAME>`. Chapter 7 shows how to set them.
- Google Workspace and GCP use **no stored secret**. The Lambda's AWS role federates into Google
  through Workload Identity Federation.

The same ingester image also runs outside AWS as `ingester daemon`, which runs the same schedule and
worker loops in one process.

---

## 2. The filtered bucket is the hub

After Vector, every consumer reads the **filtered bucket**. Three things happen for each new object:

| Consumer | Triggered by | Queue |
|---|---|---|
| Detection | S3 notification per lane prefix `<lane>/` | `<p>-filtered-<lane>` (+ `<p>-filtered-dlq`) |
| Quickwit | EventBridge rule per index | `<p>-quickwit-<index>` (+ `<p>-quickwit-dlq`) |
| Athena | nothing: Glue tables read the bucket directly | none |

EventBridge is used for Quickwit because an S3 bucket can only send one notification per prefix. The
detection queues already use those notifications, so EventBridge fans a second copy out to Quickwit.

---

## 3. Detection

```
 SQS <p>-filtered-<lane> ──► detection-engine (ECS Fargate, one service per lane)
                               1. receive ONE message; keep extending its visibility while working
                               2. download the object, decode every record
                               3. evaluate every Sigma rule in rules/<lane>/
                               4. publish each match as a detection.alert.v1 message
                               5. delete the message only after all alerts are sent
                                        │
                                        ▼
                             SQS <p>-detections-alerts (+ -dlq)
```

The SQS queues detection needs:

| Queue | Who writes | Who reads | Notes |
|---|---|---|---|
| `<p>-filtered-<lane>` | S3 (filtered bucket) | detection-engine for that lane | visibility 900 s, DLQ after 5 receives |
| `<p>-filtered-dlq` | SQS redrive | you, plus an alarm | objects the engine failed on 5 times |
| `<p>-detections-alerts` | every detection-engine | alert-destination | visibility = 6 × the Lambda timeout |
| `<p>-detections-alerts-dlq` | SQS redrive | you, plus an alarm | alerts that could not be delivered |

How the engine behaves:

- **Rules are Sigma YAML**, baked into the detection-engine image under `rules/<lane>/`. There are 65
  in total, most of them for the `aws` lane. Each rule has a test file with at least one event that
  must fire it. You can also ship your own rules folder with Terraform (`rules_dir`).
- **It fails closed.** A broken rule stops the service from starting, rather than letting it run
  with a hole in its coverage.
- **The alert id is deterministic.** It is `det_` + sha256(rule, lane, bucket, key, record index).
  Processing the same object twice gives the same id, so nobody downstream is alerted twice.
- **Only stateless rules are supported:** one record at a time, with no counting or correlation over
  time windows.

An alert looks like this (shortened):

```json
{
  "schema_version": "detection.alert.v1",
  "id": "det_4f1c…",
  "alerted_at": "2026-09-28T10:14:03Z",
  "log_source": "aws",
  "rule": { "id": "…", "title": "CloudTrail Logging Disabled", "level": "high", "tags": ["attack.defense_evasion"] },
  "provenance": { "bucket": "siem-filtered-…", "key": "aws/date=2026-09-28/….gz", "event_index": 17 },
  "event": { "eventName": "StopLogging", "userIdentity": { "…": "…" } }
}
```

---

## 4. Alerts to Slack and GitHub

```
 SQS <p>-detections-alerts ──► alert-destination (Lambda, batch 1, up to 5 in parallel)
                                 1. route: pick destinations by level + lane
                                 2. archive → s3://<p>-detections-…/alerts/log_source=<lane>/date=…/<id>.json
                                 3. Slack  → chat.postMessage to the routed channel
                                 4. GitHub → open an issue in the routed repo (critical by default)
                                 ledger: DynamoDB <p>-alert-destination-ledger
```

1. **Routing.** A YAML table (SSM `/<p>/alert-destination/ROUTES`) picks destinations by alert
   `level` and lane. The most specific route wins. Every route must include Slack, so a human always
   sees an alert.

   ```yaml
   routes:
     - level: critical
       log_source: "*"
       deliveries:
         - {to: slack, target: "C0EXAMPLE1"}
         - {to: github, target: "example-org/security-alerts"}
     - level: "*"
       log_source: "*"
       deliveries:
         - {to: slack, target: "C0EXAMPLE1"}
   default:
     deliveries:
       - {to: slack, target: "C0EXAMPLE1"}
   ```

2. **Archive first.** The alert is written to the detections bucket before anyone is notified, so
   every alert anyone saw is also on record. You can query the archive in Athena as the table
   `detections`.
3. **Deliver exactly once per destination.** The DynamoDB ledger records each delivery, keyed on
   alert id + destination + target. A retry only sends to the destinations that are still missing.
4. **Fail loudly.** If any destination fails, the Lambda fails. SQS then retries, and after 5 tries
   the alert lands in `<p>-detections-alerts-dlq`, which has an alarm.

In **Slack** an alert appears as a message showing the severity, rule, lane, the S3 location of the
record and an excerpt of the event. In **GitHub** it appears as an issue titled
`[LEVEL] <rule title> (<alert id>)`, labelled `detection`, `severity:<level>` and `source:<lane>`.
The labels must already exist in the repository.

---

## 5. Search: Quickwit, Athena and Grafana

### Quickwit: the last 90 days, fast

```
 filtered bucket ──(EventBridge Object Created)──► SQS <p>-quickwit-<index> ──► Quickwit (ECS)
```

- There are five indexes: `logs-aws`, `logs-github`, `logs-dns`, `logs-alb` and `logs-saas`. The
  last one holds slack, onepassword, workspace, gcp and cloudflare.
- Quickwit reads each new object from the queue and indexes it within about 30 seconds.
- Retention is 90 days. The index files and the metastore live in their own S3 bucket.
- The indexes are created automatically when Quickwit starts.
- Quickwit has **no login of its own**. It is only reachable through the load balancer's OIDC login.

### Athena: everything, with SQL

- There is one Glue table per lane, `filtered_<lane>`, over the filtered bucket (1 year), plus
  `detections` over the alert archive.
- Each table has a single column, `line`, holding the raw JSON. You read fields with
  `json_extract_scalar(line, '$.path')`.
- Always filter on `date`. The workgroup refuses queries that scan more than 100 GB.

```sql
SELECT json_extract_scalar(line, '$.eventName')  AS event,
       json_extract_scalar(line, '$.userIdentity.arn') AS who
FROM   filtered_aws
WHERE  date >= '2026-09-21'
  AND  json_extract_scalar(line, '$.eventName') = 'ConsoleLogin';
```

### Grafana: dashboards on top of both

Grafana ships with five Quickwit datasources (one per index), one Athena datasource and ten
dashboards:

- volume and coverage per lane
- failed and denied API calls
- IAM and privilege changes
- GitHub audit activity
- DNS activity
- ALB connections and TLS
- "who did what" across lanes
- index fidelity (Quickwit versus Athena counts)
- deep history beyond 90 days (Athena)
- network traffic (Athena)

You open it at `https://grafana.<your-domain>`, behind the same OIDC login as Quickwit.

---

## Recap: every SQS queue in the system

| Queue | Stage | Fed by | Read by |
|---|---|---|---|
| `<p>-raw-<source>` | ingest | S3 notification on a raw bucket | Vector |
| `<p>-ingester-<lane>-slices` (+`-dlq`) | ingest | ingester schedule / reconcile / backfill | ingester worker |
| `<p>-filtered-<lane>` (+`<p>-filtered-dlq`) | detect | S3 notification on the filtered bucket | detection-engine |
| `<p>-quickwit-<index>` (+`<p>-quickwit-dlq`) | search | EventBridge on the filtered bucket | Quickwit |
| `<p>-detections-alerts` (+`-dlq`) | alert | detection-engine | alert-destination |

Every DLQ has a CloudWatch alarm that emails `alarm_email` as soon as it holds a message. Each
filtered lane queue also has an alarm on the age of its oldest message.

## Next

Continue to **[7. Deploy your own AWS SIEM](../7-aws-siem-deploy/README.md)**.

More detail for each AWS log producer is in
[`aws-siem/docs/aws-log-sources.md`](https://github.com/samma-io/aws-siem/blob/main/docs/aws-log-sources.md).
