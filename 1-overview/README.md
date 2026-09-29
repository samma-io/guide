# 1. What is Samma?

Samma has two parts that answer two different questions:

| | **Samma scanner** | **Samma AWS SIEM** |
|---|---|---|
| Question | *What does the outside world see of my hosts?* | *What is happening in my cloud and SaaS accounts?* |
| Input | targets you add: hostnames or IPs | logs: CloudTrail, VPC flow, DNS, GitHub, Slack, 1Password, Google, Cloudflare, … |
| Runs on | any Kubernetes cluster | your AWS account (S3, SQS, ECS Fargate, Lambda) |
| Output | findings per target in the Samma dashboard and Grafana | Sigma alerts in Slack / GitHub, search in Quickwit, Grafana and Athena |
| Chapters | 2–5 | 6–7 |

They are **independent**. You can run either one without the other.

## The scanner

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

## Repositories

| Repo | Part | What it is |
|---|---|---|
| [`app`](https://github.com/samma-io/app) | scanner | The Samma dashboard (Next.js + Postgres) |
| [`operator`](https://github.com/samma-io/operator) | scanner | Operator, target API, NATS, TimescaleDB, bridge and Grafana dashboards (Helm chart) |
| [`detect`](https://github.com/samma-io/detect) | scanner | The detect scanner images, plus a Helm chart for standalone scheduled scans |
| [`deploy`](https://github.com/samma-io/deploy) | scanner | GitOps (ArgoCD) manifests for the dashboard |
| [`aws-siem`](https://github.com/samma-io/aws-siem) | SIEM | Terraform for the whole AWS SIEM, docs and contracts |
| `vector`, `ingester`, `detection-engine`, `alert-destination`, `quickwit`, `grafana` | SIEM | The SIEM services |

## The path through this guide

| Step | You will |
|---|---|
| [2. Run a scanner locally](../2-run-a-scanner-locally/README.md) | run one scanner with Docker and read its findings. You need only Docker. |
| [3. Deploy the scanner](../3-deploy-the-scanner/README.md) | install the operator stack and the dashboard in Kubernetes |
| [4. Your first scan](../4-first-scan/README.md) | add a target, watch the scan run, and find the results |
| [5. Targets, profiles and baselines](../5-targets-profiles-baselines/README.md) | choose scanners, automate targets, and spot changes over time |
| [6. AWS SIEM: how the data flows](../6-aws-siem-data-flow/README.md) | understand the SIEM pipeline end to end |
| [7. Deploy your own AWS SIEM](../7-aws-siem-deploy/README.md) | deploy the SIEM into a clean AWS account, including SSM setup for every source |

You only want the SIEM? Skip to chapter 6.

## Only scan what you own

Scanning a host you do not own or have permission to test can be illegal. Samma does not yet
check that your organisation owns a target; it only blocks private and loopback addresses. Only
add targets you are allowed to scan. For practice, use `scanme.nmap.org`, which exists for this
purpose, or a host of your own.
