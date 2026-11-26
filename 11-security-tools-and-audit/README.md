# 11. Security tools, Keycloak and the API audit log

Chapter 10 fed Traefik's access log into the SIEM. This chapter adds the rest of the cluster's
security signal:

- **Keycloak:** logins, failed logins, admin logins, MFA removed, impersonation.
- **The Kubernetes API audit log:** exec into pods, secret reads, RBAC and webhook changes, 403s.
- **Falco, OPA Gatekeeper and open-appsec:** what your runtime sensor, admission policy and WAF
  already decide.
- **trivy-operator:** critical CVEs, secrets baked into images and risky workload settings.

Every one of them is a `detections.<name>` switch in the `samma-siem` chart. The chart deploys the
lane; you connect the tool.

## What you will learn

- The three ways a tool reaches the SIEM, and which one each tool uses.
- How to turn on each detection and connect its tool.
- How to check that records arrive, and trigger a test alert where you can.

## Three flows

Every input here takes one of three paths:

| Flow | How records arrive | Used by |
|---|---|---|
| **A. Pod log lane** | The tool logs to stdout. You label its pods `samma.io/detection: <lane>`, the node shipper from chapter 10 forwards the lines, and the log router keeps only allowed lanes and namespaces. | Keycloak, Falco, Gatekeeper, open-appsec |
| **B. Push lane** | The tool POSTs JSON to the log router's port `8080` at `/v1/<lane>`, with a bearer token. | trivy-operator |
| **C. Audit collector** | A DaemonSet on the control-plane nodes reads the API server's audit log file and filters it before anything is sent. | the Kubernetes API audit log |

```
 A  pod stdout ─► node shipper ─► k8s-log-router :24224/:6000 (allowlist) ─┐
 B  tool ──POST /v1/<lane> + token──► k8s-log-router :8080 ────────────────┴─► samma.logs.svc.<lane> (SIEM_SERVICES) ─► detection-engine-<lane>
 C  kube-apiserver audit log ─► k8s-audit-collector (filter) ─► samma.audit.k8s (SIEM_AUDIT) ─► detection-engine-k8s
                                                                                                        │
                                                         samma.alerts.<lane> ─► alert-destination ─► siem_alerts ◄┘
```

Flows A and B use the same router, stream and engines as Traefik. A new tool on those paths is
a router entry and a rules folder, nothing else.

## Before you start

- The SIEM from chapter 8.
- For flow A, the node shipper from chapter 10, step 2. Without it, nothing in this chapter
  except trivy-operator and the audit log reaches the SIEM.
- A detection-engine image with the lanes you turn on: `keycloak`, `falco`, `trivy`,
  `gatekeeper` and `openappsec` are new. An older image refuses to start a lane it does not
  know.

## 1. Keycloak

Keycloak writes its user events to its normal log, as lines from the `org.keycloak.events`
logger:

```
2026-11-25 10:00:00,123 WARN  [org.keycloak.events] (executor-thread-11) type="LOGIN_ERROR", realmName="example", clientId="account-console", ipAddress="192.0.2.10", error="invalid_user_credentials", username="alice"
```

The router's `keycloak` parser keeps only those lines and turns each `key="value"` into a field
(`type`, `clientId`, `ipAddress`, `error`, ...). Every other Keycloak log line is dropped at the
router.

Turn on the detection, listing the namespaces your Keycloak pods run in:

```yaml
detections:
  keycloak: {enabled: true, namespaces: [keycloak]}
```

Then, on the Keycloak Deployment or StatefulSet:

```yaml
spec:
  template:
    metadata:
      labels:
        samma.io/detection: keycloak        # on the pod template, not the Deployment
    spec:
      containers:
        - name: keycloak
          env:
            # Log successful events too, not only failures: needed for the admin login,
            # password, MFA, IdP link and impersonation rules.
            - name: KC_SPI_EVENTS_LISTENER_JBOSS_LOGGING_SUCCESS_LEVEL
              value: info
```

In each realm, check that **Realm settings → Events → User events settings** is on, with the
event types you care about saved. Admin events (changes made in the admin console) need **Admin
events settings** turned on too.

**Test:** log in to an app in a test realm with a wrong password. Within seconds:

```sql
SELECT alerted_at, level, rule_title FROM siem_alerts
WHERE log_source = 'keycloak' ORDER BY alerted_at DESC LIMIT 5;
-- low | Keycloak Login Failure
```

| Rule | Level |
|---|---|
| Login failure (bad password, unknown user, locked out) | low |
| Admin console / `admin-cli` login failure | medium |
| Admin console / `admin-cli` login | medium |
| MFA removed (TOTP, WebAuthn) | medium |
| Password changed or reset | low |
| Identity provider linked to an account | medium |
| Client credentials failure (bad client secret) | medium |
| Impersonation | high |

## 2. The Kubernetes API audit log

The API server can write one JSON line per request to a file on each control-plane node. That
file is the record of who did what in the cluster, but it is large: several GB a day even on a
small cluster, almost all of it controllers renewing their own state.

```yaml
detections:
  k8s: {enabled: true}
```

The chart runs `samma-siem-k8s-audit-collector` on the control-plane nodes. It reads the log
file and sends only what a rule can use, which is about 20 MB a day on a small cluster:

- **Kept:** 401 and 403 responses, anonymous requests, every write by a person or a controller,
  and the sensitive reads: secrets, `pods/exec`, `attach`, `portforward`, `log` and service
  account tokens.
- **Dropped:** nodes and control-plane components, leases, access reviews, status updates,
  watches, other reads, and operators rewriting their own ConfigMaps.
- **Never sent:** response bodies, and request bodies except for pods, services and RBAC
  objects. A Secret or ConfigMap body never leaves the node.

Your API server needs an audit policy. Talos writes one by default to
`/var/log/audit/kube/kube-apiserver.log`, which is the chart's default. On kubeadm, set
`auditCollector.logDir` and `auditCollector.logFile` from `--audit-log-path`. A policy at
`Metadata` level is enough for every rule except the two that read the request body (privileged
pod, NodePort Service).

**Test:**

```bash
kubectl -n default run audit-test --image=busybox:1.36 --restart=Never -- sleep 300
kubectl -n default exec -it audit-test -- sh -c 'id'
kubectl -n default delete pod audit-test
```

```sql
SELECT alerted_at, level, rule_title FROM siem_alerts
WHERE log_source = 'k8s' ORDER BY alerted_at DESC LIMIT 5;
-- high | Kubernetes Exec Into Pod
```

kubectl 1.30 and later open exec, attach and port-forward over a websocket, which the audit log
records as verb `get`, not `create`. The rules match both.

## 3. Falco

Falco watches system calls on every node and logs an alert when a rule matches: a shell in a
container, a write below `/etc`, a binary dropped and run.

```yaml
detections:
  falco: {enabled: true, namespaces: [falco]}
```

Install Falco with JSON output, its alert text and tags included, and the pod label:

```bash
helm upgrade --install falco falcosecurity/falco -n falco --create-namespace \
  --set falco.json_output=true \
  --set falco.json_include_output_property=true \
  --set falco.json_include_tags_property=true \
  --set-json 'podLabels={"samma.io/detection":"falco"}'
```

Falco is a privileged DaemonSet with access to every node's kernel events. Install it like any
other node-level agent, through your normal change process.

**Test:** `kubectl exec -it` into any pod and run `sh`. Falco logs **Terminal shell in
container**, and the SIEM alerts at medium.

| Rule | Level |
|---|---|
| Falco priority Critical, Alert or Emergency | high |
| Falco priority Error or Warning | medium |
| Terminal shell in container | medium |
| Any other Falco priority Notice | low |

Severity is Falco's own priority. Tune noisy rules in Falco, where they fire, rather than here.

## 4. OPA Gatekeeper

Gatekeeper refuses objects that break your policies, and its audit finds existing objects that
break them.

```yaml
detections:
  gatekeeper: {enabled: true, namespaces: [gatekeeper-system]}
```

```bash
helm upgrade --install gatekeeper gatekeeper/gatekeeper -n gatekeeper-system --create-namespace \
  --set logDenies=true \
  --set-json 'podLabels={"samma.io/detection":"gatekeeper"}'
```

| Rule | Level |
|---|---|
| Admission denied by a constraint | low |
| Audit found a running privileged or host-access workload | medium |

## 5. open-appsec

open-appsec is a WAF that runs next to your ingress. Its agent logs each security event as JSON.

```yaml
detections:
  openappsec: {enabled: true, namespaces: [open-appsec]}
```

Label the agent pods `samma.io/detection: openappsec`, and set its log destination to stdout in
JSON format.

| Rule | Level |
|---|---|
| Critical or high attack detected but not blocked (detect mode) | high |
| Critical or high attack blocked (prevent mode) | medium |

## 6. trivy-operator (push)

trivy-operator scans every workload's image and settings, and keeps the results as reports in
the cluster. It can also POST each report to a webhook, and that is how it reaches the SIEM.

Create the token, then turn on the detection:

```bash
TOKEN=$(openssl rand -hex 32)
kubectl -n samma-siem create secret generic samma-siem-push --from-literal=PUSH_TOKEN_TRIVY="$TOKEN"
```

```yaml
detections:
  trivy: {enabled: true}
logRouter:
  push:
    existingSecret: samma-siem-push
```

Point trivy-operator at the router:

```bash
helm upgrade --install trivy-operator aqua/trivy-operator -n trivy-system --create-namespace \
  --set operator.webhookBroadcastURL=http://samma-siem-k8s-log-router.samma-siem.svc:8080/v1/trivy \
  --set-string operator.webhookBroadcastCustomHeaders="Authorization:Bearer $TOKEN"
```

The router answers **401** to a wrong token, and to any lane that has no token. Its `trivy`
parser keeps each report's kind, workload, image, summary counts and up to 20 critical or high
findings. It never keeps the text of a matched secret.

**Test** from a pod in the cluster:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  http://samma-siem-k8s-log-router.samma-siem.svc:8080/v1/trivy \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"kind":"VulnerabilityReport","metadata":{"name":"test"},"report":{"summary":{"criticalCount":1}}}'
# 200, and a high "Trivy Critical Vulnerability in Running Image" alert
```

| Rule | Level |
|---|---|
| Critical vulnerability in a running image | high |
| Secret found in an image | high |
| Critical workload or node misconfiguration | medium |
| Critical RBAC permission | medium |

trivy-operator rescans every workload regularly (by default every 24 hours), and resends the
report each time. The same finding alerts again after each rescan until it is fixed.

## Check every hop

From a nats-box in the cluster:

```bash
nats sub 'samma.logs.svc.>'          # flows A and B, one subject per lane
nats sub 'samma.audit.k8s'           # flow C
nats consumer info SIEM_SERVICES detection-engine-keycloak
nats consumer info SIEM_AUDIT detection-engine-k8s
```

## When something is missing

| Symptom | Likely cause |
|---|---|
| Keycloak logs arrive at the shipper, but nothing on `samma.logs.svc.keycloak` | No `org.keycloak.events` lines yet: Keycloak logs failures only, unless the success level is set (step 1). |
| No audit events | The collector is not on the node that writes the log (check `auditCollector.nodeSelector`), or the API server has no audit policy. |
| The audit collector cannot read the log | The file's owner is not uid 65534: set `auditCollector.runAsUser` to the owner. |
| trivy-operator logs 401 | The token in its header is not the one in `PUSH_TOKEN_TRIVY`, or the router has not restarted since the Secret changed. |
| A security tool's lane is empty | The label is on the Deployment, not on the pod template, or the tool's namespace is not listed in the detection. |
| The engine refuses a lane | Its image predates that lane. |

## Where the data lives

| Data | Where | Kept for |
|---|---|---|
| Keycloak, Falco, Gatekeeper, open-appsec, trivy records | `SIEM_SERVICES` (`samma.logs.svc.<lane>`) | 24 hours or 100 MiB |
| Filtered API audit events | `SIEM_AUDIT` (`samma.audit.k8s`) | 3 days or 64 MiB |
| Alerts | `SIEM_ALERTS`, then Postgres `siem_alerts` | 30 days in the stream; the table as you keep it |

The Falco, trivy, Gatekeeper and open-appsec rules are marked experimental. Their test events
follow each tool's documented output; check the first real alerts after you install a tool.
