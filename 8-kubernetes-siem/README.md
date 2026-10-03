# 8. The Kubernetes SIEM, and how it fits with the AWS SIEM

Samma has two SIEMs. The [AWS SIEM](../6-aws-siem-data-flow/README.md) (chapters 6 and 7) watches
your cloud and SaaS accounts. The **Kubernetes SIEM**, covered in this chapter, runs inside a cluster
and watches what happens in that cluster.

This chapter explains what the Kubernetes SIEM is and how to try it. It ends with a side-by-side
comparison, to help you decide which SIEM to run, or whether to run both.

## What you will learn

- How events flow through the Kubernetes SIEM, from container logs to Grafana.
- How its YAML rules are written.
- How to run the example stack in a cluster.
- How it compares with the AWS SIEM, and how to run the two side by side.

## The repositories

| Repo | What it is |
|---|---|
| [`siem`](https://github.com/samma-io/siem) | The rule engine (Go). It reads JSON events from NATS or HTTP and publishes alerts to NATS. It also holds example manifests and Grafana dashboards. |
| [`siem-rules`](https://github.com/samma-io/siem-rules) | The detection rules: 27 for Kubernetes audit events, plus one for nmap and one for Nikto |
| [`siem-storage`](https://github.com/samma-io/siem-storage) | An optional JetStream consumer that writes events and alerts to Elasticsearch |

---

## How the data flows

```
                                   samma.logs.k8s.*
  Fluent Bit ──► Vector ─────────────────────────────► NATS
  (DaemonSet)   (aggregator)                            │
                                                        │ subscribe: samma.logs.>
                                                        ▼
                                                       SIEM  (rule engine)
                                                        │
                                                        │ publish: samma.alerts.<category>.<type>
                                                        ▼
                                                       NATS
                                                        │
                                                        │ subscribe: samma.alerts.>
                                                        ▼
                                              Alert sink (Vector)
                                                        │
                                                        ▼
                                     Elasticsearch  samma-alerts-<severity>
                                                        │
                                                        ▼
                                                     Grafana
```

1. **Fluent Bit** runs on every node and tails `/var/log/containers/*.log`. The `k8s` rules match
   Kubernetes audit events (`kind: Event`). Getting those into the stream means writing the API
   server audit log where Fluent Bit can read it, or adding it as a second input.
2. **Vector** formats each line and publishes it to NATS on `samma.logs.k8s`.
3. The **SIEM** subscribes to `samma.logs.>` and checks every event against every rule. When a rule
   matches, the SIEM publishes an alert, made of the rule metadata and the original event, to that
   rule's own NATS subject.
4. A second **Vector**, the alert sink, subscribes to `samma.alerts.>` and writes each alert to
   Elasticsearch, with one index per severity. A [Loki variant](https://github.com/samma-io/siem/tree/main/examples/logging)
   is also available.
5. **Grafana** ships with two dashboards: *Compliance Overview* and *Service Alerts*.

The SIEM also accepts events over HTTP at `POST /ingest`, which is handy for testing a rule.

The rule engine keeps no state. It has no aggregation, thresholds or time windows. Each event is
matched on its own.

## The rule format

Each rule is one YAML file. Here is `rules/k8s/k8s_anonymous_access.yaml`, shortened:

```yaml
name: k8s-anonymous-access
description: Detects anonymous or unauthenticated API requests
severity: critical                         # low | medium | high | critical
nats_subject: samma.alerts.k8s.anonymous_access

compliance:
  pci_dss: ["10.2.5", "8.1.2"]
  nist_800_53: ["AC.2", "IA.2"]
  mitre: ["T1078"]

match:
  and:
    - field: kind
      equals: Event
    - field: user.username
      equals: "system:anonymous"
```

- `match` takes `and` and `or`, which can be nested. Each condition compares a dotted field path
  using either `equals` or `regex`.
- `compliance` maps the rule to PCI DSS, GDPR, HIPAA, NIST 800-53, MITRE ATT&CK, TSC and GPG13. The
  Grafana compliance dashboard groups alerts by these mappings.
- Every rule has a JSON test fixture under `test/`. Run `python test_rules.py` in `siem-rules`.

## Try it

The [`siem/examples/simple`](https://github.com/samma-io/siem/tree/main/examples/simple) folder
has a step-by-step install for any cluster: minikube, kind or a managed one. In short:

```bash
git clone https://github.com/samma-io/siem
git clone https://github.com/samma-io/siem-rules
cd siem/examples/simple

kubectl apply -f namespace.yaml
helm install nats       nats/nats             -n samma -f nats-values.yaml
helm install vector     vector/vector         -n samma -f vector-values.yaml
helm install fluent-bit fluent/fluent-bit     -n samma -f fluent-bit-values.yaml
kubectl create configmap siem-rules -n samma --from-file=../../../siem-rules/rules/
kubectl apply -f siem.yaml -f elasticsearch.yaml -f alert-sink.yaml -f grafana.yaml
```

Then fire a test event, and look for the matching alert in Grafana (`admin` / `samma`):

```bash
kubectl exec -n samma deployment/nats-box -- nats pub samma.logs.k8s.test \
  '{"kind":"Event","objectRef":{"resource":"users"},"verb":"authenticate"}'
kubectl port-forward -n samma svc/grafana 3000:3000
```

The example README covers each step, including how to add the Helm repositories and how to clean
up afterwards.

---

## Kubernetes SIEM or AWS SIEM?

They answer different questions, so most teams pick the one that matches where their workloads
run. Some teams run both.

| | **Kubernetes SIEM** | **AWS SIEM** |
|---|---|---|
| Question | *What is happening inside my cluster?* | *What is happening in my cloud and SaaS accounts?* |
| Runs on | any Kubernetes cluster | your AWS account (S3, SQS, ECS Fargate, Lambda) |
| Input | container logs and Kubernetes audit events (Fluent Bit → Vector → NATS) | CloudTrail, VPC flow, DNS, ALB, GitHub audit, Slack, 1Password, Google Workspace, GCP, Cloudflare |
| Rules | Samma YAML (`equals` / `regex`), compliance-mapped | [Sigma](https://sigmahq.io/), with a test per rule |
| Alerts | NATS → Elasticsearch or Loki → Grafana | S3 archive → Slack → GitHub issues |
| Search | Grafana over Elasticsearch or Loki | Quickwit (90 days), Athena (raw data kept 6 years), Grafana |
| Install | Helm charts and manifests in your cluster | Terraform into a clean AWS account ([chapter 7](../7-aws-siem-deploy/README.md)) |
| Cost floor | whatever your cluster already costs | about 250–300 USD per month |

**Pick the Kubernetes SIEM** if your workloads live in Kubernetes, you already run NATS or the
Samma scanner, and you want alerts next to the rest of your cluster tooling.

**Pick the AWS SIEM** if most of your risk sits in AWS and in SaaS tools like GitHub, Slack and
1Password, and you want long retention and alerts in Slack and GitHub.

**Run both** if you run Kubernetes on AWS. The Kubernetes SIEM watches the cluster, and the AWS
SIEM watches the account it runs in. They don't conflict: they share no code, queues or storage.
Point both at the same Grafana if you want one place to look.

### What they do *not* do (yet)

- **They don't exchange data.** An alert raised by the Kubernetes SIEM doesn't show up in the AWS
  SIEM's Slack or GitHub routing, and the AWS SIEM has no Kubernetes lane. Forwarding cluster
  alerts into an AWS SIEM lane is a possible future step, but it isn't built.
- **Scanner findings don't reach either SIEM by default.** The scanner (chapters 2–5) sends its
  findings to TimescaleDB and the Samma dashboard. The nmap and Nikto rules in `siem-rules` only
  fire if you publish scanner events to `samma.logs.>` yourself, or `POST` them to `/ingest`.

## Next steps

- New to the AWS side? Read [6. AWS SIEM: how the data flows](../6-aws-siem-data-flow/README.md).
- Ready to deploy on AWS? Go to [7. Deploy your own AWS SIEM](../7-aws-siem-deploy/README.md).
- Back to the [guide index](../README.md).
