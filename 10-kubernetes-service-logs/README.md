# 10. Kubernetes service logs: start with Traefik

Chapter 8 runs the SIEM on SaaS audit logs. This chapter feeds it the logs of services **inside your
cluster**. Traefik's access log is the first: every request that reaches your ingress is checked for
probes, path traversal, SQL injection, Log4Shell strings and attack tools.

You opt a workload in with one pod label. The SIEM decides which labels it accepts.

## What you will learn

- How a pod's log line becomes an alert, and what the log router allows through.
- How to turn on the Traefik detection in the `samma-siem` chart.
- How to connect a node log shipper (fluent-bit or a Vector agent).
- How to turn on Traefik's JSON access log and opt Traefik in.
- How to check every hop, trigger a test alert, and read the Traefik rules.

## How the data flows

```
 Traefik pod                    every node                k8s-log-router              detection-engine-traefik
 label samma.io/detection:      fluent-bit or a           (allowlist: lane +          (Sigma rules,
 traefik, JSON access log       Vector agent              namespace)                  rules/traefik/)
      │                              │                          │                            │
      ▼                              ▼                          ▼                            ▼
 stdout ─► /var/log/containers ─► adds pod metadata ─► keeps allowed records ─► samma.logs.svc.traefik ─► samma.alerts.traefik ─► alert-destination ─► siem_alerts
                                                                                 (SIEM_SERVICES)            (SIEM_ALERTS)
```

1. **Traefik writes** one JSON line per request to stdout. The container runtime puts it in the
   node's log files.
2. **The node shipper** tails every container log and adds the pod's metadata: namespace, pod name
   and labels. It sends everything to the log router.
3. **The log router** keeps a record only when the pod's `samma.io/detection` label names a lane in
   its allowlist **and** the pod runs in a namespace allowed for that lane. It parses the JSON line,
   adds the SIEM envelope (`source`, `feed`, `event_time`, `k8s`, `search_text`) and publishes it on
   `samma.logs.svc.<lane>`. Everything else is dropped.
4. **The detection engine** for the lane runs its Sigma rules and publishes matches as alerts,
   which reach `siem_alerts` and your routes exactly as in chapter 8.

**Why an allowlist?** The label is only a request. Without the allowlist, anyone allowed to label a
pod could write into any lane, for example `wazuh`, and forge or flood its alerts. The router also
writes the envelope last, so a log line cannot pretend to come from another namespace.

**Why a stream of its own?** Access logs are bursty. `SIEM_SERVICES` (24 hours, 100 MiB) holds only
service lanes, so a burst can never push other lanes' records out of `SIEM_LOGS`. These records are
for detection only: siem-storage does not copy them into `siem_events`.

## Before you start

You need:
- the SIEM from chapter 8, installed from `samma-siem` chart **0.5.0 or later**
- detection-engine image **`5a4e082` or later** (the chart default), which knows the
  `traefik` lane
- Traefik installed with its Helm chart (v31 or later), in namespace `traefik` in the examples
- a node log shipper, or permission to install one

## 1. Turn on the Traefik detection

Turn on the detection, with the namespaces allowed to feed it:

```yaml
# traefik-detection.yaml
detections:
  traefik: {enabled: true, namespaces: [traefik]}
```

```bash
helm upgrade samma-siem chart/samma-siem -n samma-siem -f siem-values.yaml -f traefik-detection.yaml
```

The upgrade adds:

| Object | Name |
|---|---|
| stream | `SIEM_SERVICES` (`samma.logs.svc.>`) |
| consumer | `detection-engine-traefik` on `SIEM_SERVICES` |
| Deployment and Service | `samma-siem-detection-engine-traefik` |
| Deployment, ConfigMap and Service | `samma-siem-k8s-log-router` (ports 24224 and 6000) |

Check that the engine loaded its rules:

```bash
kubectl -n samma-siem logs deploy/samma-siem-detection-engine-traefik | grep "ruleset loaded"
# "rules":6, "by_level":{"high":2,"low":2,"medium":2}
```

## 2. Connect a node shipper

The router has no access to the Kubernetes API and no host mounts. The shipper on each node reads
the logs and adds the pod metadata. Unlabelled records are dropped cheaply, so the shipper can send
everything.

### fluent-bit

If you run the fluent-bit Helm chart, add an output next to the ones you have:

```yaml
# fluent-bit values
config:
  outputs: |
    [OUTPUT]
        Name          forward
        Match         kube.*
        Host          samma-siem-k8s-log-router.samma-siem.svc.cluster.local
        Port          24224
        Retry_Limit   5
```

`Retry_Limit` stops a router outage from holding back your other outputs.

The fluent-bit `kubernetes` filter must be able to read pods. Otherwise every record arrives
without labels and the router drops it. Check the service account:

```bash
kubectl auth can-i list pods -A --as=system:serviceaccount:<fluent-bit namespace>:fluent-bit
# yes
```

### A Vector agent

If you run Vector as a DaemonSet instead, read only the labelled pods and send them on:

```yaml
sources:
  samma_pods:
    type: kubernetes_logs
    extra_label_selector: samma.io/detection
sinks:
  samma_router:
    type: vector
    inputs: [samma_pods]
    address: samma-siem-k8s-log-router.samma-siem.svc:6000
```

## 3. Turn on Traefik's access log and opt it in

In the Traefik Helm values, turn on the access log in JSON and keep the `User-Agent` header. Traefik
drops request headers from the access log by default, and the attack-tool rule needs that one. Then
label the pods:

```yaml
# traefik values
logs:
  access:
    enabled: true
    format: json
    fields:
      headers:
        defaultmode: drop
        names:
          User-Agent: keep
deployment:
  podLabels:
    samma.io/detection: traefik
```

Put the label on the **pods**, as `deployment.podLabels` does. A label on the Deployment object
itself does not travel with the logs.

Traefik rolls its pods. If Traefik is managed by ArgoCD, diff before you sync: a full sync applies
every difference between your values and the cluster, not only this one.

## 4. Check every hop

From a nats-box in the cluster:

```bash
# records arrive on the lane
nats sub 'samma.logs.svc.traefik'

# the stream grows, and the engine keeps up (no pending messages)
nats stream info SIEM_SERVICES
nats consumer info SIEM_SERVICES detection-engine-traefik
```

A record looks like this (shortened):

```json
{
  "ClientHost": "203.0.113.7",
  "RequestMethod": "GET",
  "RequestHost": "app.example.com",
  "RequestPath": "/.env",
  "DownstreamStatus": 404,
  "RouterName": "websecure-app@kubernetes",
  "request_User-Agent": "Mozilla/5.0 ...",
  "source": "traefik",
  "feed": "k8s",
  "event_time": "2026-11-26T06:20:50.197Z",
  "k8s": {"namespace": "traefik", "pod": "traefik-7d9f8b6c5-x2k4p", "container": "traefik", "node": "worker-1"},
  "search_text": "{\"RequestPath\":\"/.env\", ...}"
}
```

Traefik's own log lines (configuration errors, for example) come through too. They have no
`RequestPath`, so no rule matches them.

## 5. Trigger a test alert

Ask your ingress for a file that should never be served. Use a host you own:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://app.example.com/.env
# 404
```

Within a few seconds the engine logs `"matched":1` and the alert is in Postgres:

```sql
SELECT alerted_at, level, rule_title
FROM siem_alerts WHERE log_source = 'traefik'
ORDER BY alerted_at DESC LIMIT 5;
-- low | Request For A Sensitive File Path
```

If the answer had been `200`, the alert would be the high **Sensitive File Served With HTTP 200**
instead. That means a backend may really have handed out the file.

## The Traefik rules

The rules are in [`detection-engine`](https://github.com/samma-io/detection-engine), folder
`rules/traefik/`. Each one has a `.tests.yml` next to it.

| Rule | Level | Fires on |
|---|---|---|
| Request For A Sensitive File Path | low | `.env`, `.git/`, cloud or SSH credentials, `wp-config.php`, Spring actuator and similar, not answered 200 |
| Sensitive File Served With HTTP 200 | high | the same paths answered 200 |
| Path Traversal Attempt In Request | medium | `../` and its encoded forms, `/etc/passwd`, `/proc/self/environ` |
| SQL Injection Pattern In Request | medium | `UNION SELECT`, `' OR 1=1`, `sleep(`, `pg_sleep`, `WAITFOR DELAY`, `information_schema` |
| Known Attack Tool User-Agent | low | sqlmap, nikto, nuclei, wpscan, gobuster, ffuf, masscan and others |
| JNDI Lookup Injection (Log4Shell) | high | `${jndi:` in the URL or the User-Agent, plain or encoded |

**What to expect.** A public entry point gets a steady background of low alerts from internet
scanners probing for `.env` and `.git`. The medium and high ones deserve a look. Samma's own scanners
(nikto, nmap) also trip the User-Agent rule when they scan your ingress.

**What the rules cannot do.** The engine judges one request at a time. "Fifty 401s from one address
in a minute" needs state across requests, so there are no burst or brute-force rules yet.

### Write your own

Traefik's own field names are kept, so a rule matches them directly:

| Field | Example |
|---|---|
| `ClientHost` | `203.0.113.7` |
| `RequestMethod`, `RequestHost` | `POST`, `app.example.com` |
| `RequestPath` | the URI with its query string, not decoded: `/search?q=a%20b` |
| `DownstreamStatus` | a number: `404` |
| `RouterName`, `ServiceName`, `entryPointName` | which route and backend served it |
| `request_User-Agent` | present when the access log keeps the header |
| `k8s.namespace`, `k8s.pod` | where the log line came from |

For example, flag any request to an admin path that a backend answers successfully:

```yaml
title: Admin Path Answered Successfully
id: <a new uuid>
status: experimental
description: A request to /admin was answered 2xx.
author: you
level: medium
logsource:
  product: traefik
  service: access
detection:
  selection:
    RequestPath|startswith: /admin
    DownstreamStatus|gte: 200
  filter_errors:
    DownstreamStatus|gte: 300
  condition: selection and not filter_errors
falsepositives:
  - Your own administrators.
```

Write a `.tests.yml` with at least one event that fires, then run `make rulecheck` and `make docs`
in detection-engine. Chapter 8, "Add a Sigma rule", covers the test format and how a new rule
reaches the cluster.

## Add another service

1. Turn on its detection if the chart has one. For a lane the chart's catalog does not have yet,
   list it in `serviceLanes` with its namespaces, for example `{name: vault, namespaces: [vault]}`.
2. Label that service's pods `samma.io/detection: vault`.
3. The detection engine must know the lane: a new lane name needs a registry entry and a
   `rules/<lane>/` folder in detection-engine, and an image built from it. Until then its engine
   refuses to start, and its records wait in `SIEM_SERVICES` for at most 24 hours.

## When something is missing

| Symptom | Likely cause |
|---|---|
| Nothing in `SIEM_SERVICES` | The shipper is not sending to the router, or its records have no pod metadata (check the `can-i` command in step 2). |
| Other pods' logs arrive, but not Traefik's | The label is on the Deployment, not the pod template, or the namespace is not listed for the lane. |
| Records arrive but have no `RequestPath` | The access log is off, or not in JSON. |
| No `request_User-Agent` field | The access log drops headers; keep `User-Agent` as in step 3. |
| The engine restarts with `consumer not found` | The streams Job has not run since the detections changed: run `helm upgrade` again. |
| The engine refuses the lane | Its image is older than `5a4e082`. |

## Where the data lives

| Data | Where | Kept for |
|---|---|---|
| Traefik access records | `SIEM_SERVICES` (`samma.logs.svc.traefik`) | 24 hours or 100 MiB, whichever comes first |
| Alerts | `SIEM_ALERTS`, then Postgres `siem_alerts` | 30 days in the stream; the table as you keep it |

The raw access log never leaves your cluster, and it is not stored beyond the stream.
