# 1. What is Samma?

Samma has two parts that answer two different questions:

| | **Samma scanner** | **Samma AWS SIEM** |
|---|---|---|
| Question | *What does the outside world see of my hosts?* | *What is happening in my cloud and SaaS accounts?* |
| Input | targets you add: hostnames or IPs | logs: CloudTrail, VPC flow, DNS, GitHub, Slack, 1Password, Google, Cloudflare, … |
| Runs on | any Kubernetes cluster | your AWS account (S3, SQS, ECS Fargate, Lambda) |
| Output | findings per target in the Samma dashboard and Grafana | Sigma alerts in Slack / GitHub, search in Quickwit, Grafana and Athena |
| Chapters | 1a–5 | 6–7 |

They are **independent**. You can run either one without the other.

There is also a third, smaller part: the **Kubernetes SIEM**. It runs YAML detection rules on
events inside a cluster, over NATS. It doesn't replace the AWS SIEM. It watches the cluster, while
the AWS SIEM watches your cloud accounts. [Chapter 8](../8-kubernetes-siem/README.md) covers it and
compares the two SIEMs.

## The scanner

Samma scanners are open-source security scanners that you deploy into any Kubernetes cluster:

- **They follow your Ingresses.** Annotate an Ingress and the operator starts scanners against its
  hosts. They look for TLS problems, missing security headers, open ports and OWASP-style web
  findings. Delete the Ingress and its scanners are removed.
- **samma.io adds the outside view.** Connect the operator to the samma.io portal and your external
  hosts are shared with it. samma.io adds external scanners, which give you a security baseline.
- **Compliance scanners where you need them.** Tag an Ingress, for example with `pci-dss`, and
  samma.io runs a validated vendor scanner, such as a PCI ASV, against that endpoint. Use different
  vendors for different targets.
- **Results in your own Grafana.** All findings come back to Grafana inside your cluster, per
  target.
- **All of it in git.** Scanning is controlled by Ingress annotations, so it is reviewed and
  versioned with the rest of your manifests.

The right endpoints get the right scanners, and the cost stops when a target goes away.
[Chapter 1a](../1a-the-scanners/README.md) describes every scanner and what to use it for.

This is how a target becomes findings:

```
 you ──► Samma dashboard (Next.js)  ──PUT /target──►  operator API ──► Scanner resources (CRD)
         users · orgs · profiles                               │
         targets · API tokens                                  ▼
               ▲                                     operator: one Job (now) + one CronJob (weekly)
               │                                     per scanner in the profile
               │                                               │  each scanner pod scans the target
               │                                               ▼
               │                                        NATS  subject samma-io.scan
               │                                               │
               │                                               ▼
               │                                      bridge ──► TimescaleDB  scan_results
               └───────────── read-only ───────────────────────┤
                                                               └──► Grafana dashboards
```

- **Scanners** are small containers. Each one checks one thing and then exits. Examples: which
  ports are open, whether the TLS certificate is valid, which security headers are missing, what
  the DNS says.
- The **operator** runs in Kubernetes. It turns a target into scanner Jobs and CronJobs.
- **Findings** go from each scanner to **NATS**. A **bridge** writes them into **TimescaleDB**.
- The **dashboard** (`samma-io/app`) is where you add targets and read the results.

## The AWS SIEM

```
 AWS logs / GitHub (push to S3) ─┐
 SaaS APIs (ingester Lambda) ────┴─► S3 ─► SQS ─► Vector ─► filtered S3 ─┬─► detection-engine ─► alerts ─► Slack / GitHub
                                                                        ├─► Quickwit ─┐
                                                                        └─► Athena ───┴─► Grafana
```

Chapters 6 and 7 explain this part in depth.

## The Kubernetes SIEM

```
 container logs ─► Fluent Bit ─► Vector ─► NATS samma.logs.> ─► SIEM (YAML rules) ─► NATS samma.alerts.> ─► Elasticsearch / Loki ─► Grafana
```

Chapter 8 explains it, and when to pick it over, or alongside, the AWS SIEM.

## Repositories

| Repo | Part | What it is |
|---|---|---|
| [`app`](https://github.com/samma-io/app) | scanner | The Samma dashboard (Next.js + Postgres) |
| [`operator`](https://github.com/samma-io/operator) | scanner | Operator, target API, NATS, TimescaleDB, bridge and Grafana dashboards (Helm chart) |
| [`detect`](https://github.com/samma-io/detect) | scanner | The detect scanner images, plus a Helm chart for standalone scheduled scans |
| [`deploy`](https://github.com/samma-io/deploy) | scanner | GitOps (ArgoCD) manifests for the dashboard |
| [`aws-siem`](https://github.com/samma-io/aws-siem) | SIEM | Terraform for the whole AWS SIEM, docs and contracts |
| `vector`, `ingester`, `detection-engine`, `alert-destination`, `quickwit`, `grafana` | SIEM | The SIEM services |
| [`siem`](https://github.com/samma-io/siem), [`siem-rules`](https://github.com/samma-io/siem-rules) | K8s SIEM | The in-cluster rule engine and its YAML rules |

## The path through this guide

| Step | You will |
|---|---|
| [1a. The scanners](../1a-the-scanners/README.md) | learn what each scanner checks, and how external and vendor scanners fit in |
| [2. Run a scanner locally](../2-run-a-scanner-locally/README.md) | run one scanner with Docker and read its findings. You need only Docker. |
| [3. Deploy the scanner](../3-deploy-the-scanner/README.md) | install the operator stack and the dashboard in Kubernetes |
| [4. Your first scan](../4-first-scan/README.md) | add a target, watch the scan run, and find the results |
| [5. Targets, profiles and baselines](../5-targets-profiles-baselines/README.md) | choose scanners, automate targets, and spot changes over time |
| [6. AWS SIEM: how the data flows](../6-aws-siem-data-flow/README.md) | understand the SIEM pipeline end to end |
| [7. Deploy your own AWS SIEM](../7-aws-siem-deploy/README.md) | deploy the SIEM into a clean AWS account, including SSM setup for every source |
| [8. The Kubernetes SIEM](../8-kubernetes-siem/README.md) | run the in-cluster SIEM, and compare the two SIEMs |

You only want the SIEM? Skip to chapter 6.

## Only scan what you own

Scanning a host you do not own or have permission to test can be illegal. Samma does not yet
check that your organisation owns a target; it only blocks private and loopback addresses. Only
add targets you are allowed to scan. For practice, use `scanme.nmap.org`, which exists for this
purpose, or a host of your own.
