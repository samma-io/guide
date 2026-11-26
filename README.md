# Samma guide

A hands-on guide to the parts of Samma:

- **Samma scanner:** open-source scanners that you deploy into your Kubernetes cluster. They pick
  up your Ingresses and scan them for TLS, security header, port and OWASP-style findings. Connect
  to samma.io to add external scanners and validated vendor scanners (such as PCI DSS) per Ingress.
  All results come back to Grafana in your own cluster.
- **Samma AWS SIEM:** collect logs from your AWS accounts, GitHub and SaaS tools, run Sigma
  detections on them, send alerts to Slack and GitHub, and search everything in Grafana.
- **Samma SIEM on Kubernetes:** the same SIEM inside a cluster, over NATS JetStream, with alerts in
  PostgreSQL.

Each chapter is a folder with a `README.md`. Work through them in order, or jump to the part you need.

## The steps

| # | Chapter | You will | You need |
|---|---|---|---|
| 1 | [What is Samma?](1-overview/README.md) | understand both parts and how they fit together | a browser |
| **Scanner** | | | |
| 1a | [The scanners](1a-the-scanners/README.md) | learn what each scanner checks, and how external and vendor scanners fit in | a browser |
| 2 | [Run a scanner locally](2-run-a-scanner-locally/README.md) | run scanners with Docker, read findings, watch them travel over NATS | Docker |
| 3 | [Deploy the scanner](3-deploy-the-scanner/README.md) | install the operator stack and the Samma dashboard | a Kubernetes cluster, `kubectl`, `helm` |
| 4 | [Your first scan](4-first-scan/README.md) | add a target via the dashboard, an API token or the operator API, and read the results | chapter 3 |
| 5 | [Targets, profiles and baselines](5-targets-profiles-baselines/README.md) | choose scanners, scan Ingresses and git-managed targets, and find what changed | chapter 3 |
| 9 | [Connect external scanners](9-external-scanners/README.md) | connect a third-party scanner with its API key, enable it on a target group, and see runs and cost | the dashboard |
| **AWS SIEM** | | | |
| 6 | [AWS SIEM: how the data flows](6-aws-siem-data-flow/README.md) | follow a log from ingest through detection to alerts and search | a browser |
| 7 | [Deploy your own AWS SIEM](7-aws-siem-deploy/README.md) | deploy into a clean AWS account and set up SSM for alerting and every source | AWS account, Terraform, Docker |
| **Kubernetes SIEM** | | | |
| 8 | [The SIEM on Kubernetes](8-kubernetes-siem/README.md) | run detection over NATS with alerts in Postgres, and smoke-test it with a Google Workspace event | a Kubernetes cluster with JetStream NATS and PostgreSQL, `kubectl` |
| 10 | [Kubernetes service logs: Traefik](10-kubernetes-service-logs/README.md) | label a workload, ship its logs to a detection lane, and get alerts on Traefik access logs | chapter 8, a node log shipper |
| 11 | [Security tools, Keycloak and the API audit log](11-security-tools-and-audit/README.md) | add Keycloak, the API audit log, Falco, Gatekeeper, open-appsec and trivy-operator, each with one chart switch | chapter 10 |

Only interested in one part? The scanner is chapters 1–5 (including 1a) and 9. The AWS SIEM is chapters 1, 6 and 7. The
SIEM on Kubernetes is chapters 1, 6, 8, 10 and 11.

## Who is this for?

- **Chapters 1, 1a, 4 (dashboard part) and 6** need no tooling. They explain what happens and where to
  look.
- **Chapters 2, 3, 5, 7, 8 and 10** assume you are comfortable with a terminal, Docker, and either
  Kubernetes (scanner) or AWS and Terraform (SIEM).

## Before you start

Only scan hosts you own or have written permission to test. The examples use `scanme.nmap.org` and
`example.com`.

## The code

| Part | Repositories |
|---|---|
| Scanner | [app](https://github.com/samma-io/app), [operator](https://github.com/samma-io/operator), [detect](https://github.com/samma-io/detect), [deploy](https://github.com/samma-io/deploy) |
| SIEM (AWS and Kubernetes) | [aws-siem](https://github.com/samma-io/aws-siem), [vector](https://github.com/samma-io/vector), [ingester](https://github.com/samma-io/ingester), [detection-engine](https://github.com/samma-io/detection-engine), [alert-destination](https://github.com/samma-io/alert-destination), [k8s-log-router](https://github.com/samma-io/k8s-log-router), [siem](https://github.com/samma-io/siem), [quickwit](https://github.com/samma-io/quickwit), [grafana](https://github.com/samma-io/grafana) |

## Legacy guide

The original chapters are kept in [`legacy/`](legacy/README.md) and are no longer maintained. They
cover the first-generation Samma on Elasticsearch and Kibana, and the original custom-engine
Kubernetes SIEM.
