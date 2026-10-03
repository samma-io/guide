# Samma guide

A hands-on guide to the parts of Samma:

- **Samma scanner:** find out what the outside world can see of your hosts (open ports, TLS
  certificates, security headers, DNS and more), track it over time, and spot what changed.
- **Samma AWS SIEM:** collect logs from your AWS accounts, GitHub and SaaS tools, run Sigma
  detections on them, send alerts to Slack and GitHub, and search everything in Grafana.
- **Samma Kubernetes SIEM:** run YAML detection rules on events inside a cluster, over NATS, with
  alerts in Elasticsearch or Loki and Grafana.

Each chapter is a folder with a `README.md`. Work through them in order, or jump to the part you need.

## The steps

| # | Chapter | You will | You need |
|---|---|---|---|
| 1 | [What is Samma?](1-overview/README.md) | understand both parts and how they fit together | a browser |
| **Scanner** | | | |
| 2 | [Run a scanner locally](2-run-a-scanner-locally/README.md) | run scanners with Docker, read findings, watch them travel over NATS | Docker |
| 3 | [Deploy the scanner](3-deploy-the-scanner/README.md) | install the operator stack and the Samma dashboard | a Kubernetes cluster, `kubectl`, `helm` |
| 4 | [Your first scan](4-first-scan/README.md) | add a target via the dashboard, an API token or the operator API, and read the results | chapter 3 |
| 5 | [Targets, profiles and baselines](5-targets-profiles-baselines/README.md) | choose scanners, scan Ingresses and git-managed targets, and find what changed | chapter 3 |
| **AWS SIEM** | | | |
| 6 | [AWS SIEM: how the data flows](6-aws-siem-data-flow/README.md) | follow a log from ingest through detection to alerts and search | a browser |
| 7 | [Deploy your own AWS SIEM](7-aws-siem-deploy/README.md) | deploy into a clean AWS account and set up SSM for alerting and every source | AWS account, Terraform, Docker |
| **Kubernetes SIEM** | | | |
| 8 | [The Kubernetes SIEM, and how it fits with the AWS SIEM](8-kubernetes-siem/README.md) | run the in-cluster SIEM, and decide which SIEM to run, or both | a Kubernetes cluster, `kubectl`, `helm` |

Only interested in one part? The scanner is chapters 1–5. The AWS SIEM is chapters 1, 6 and 7. The
Kubernetes SIEM is chapters 1 and 8. Not sure which SIEM you need? Chapter 8 compares them.

## Who is this for?

- **Chapters 1, 4 (dashboard part) and 6** need no tooling. They explain what happens and where to
  look.
- **Chapters 2, 3, 5, 7 and 8** assume you are comfortable with a terminal, Docker, and either
  Kubernetes (scanner) or AWS and Terraform (SIEM).

## Before you start

Only scan hosts you own or have written permission to test. The examples use `scanme.nmap.org` and
`example.com`.

## The code

| Part | Repositories |
|---|---|
| Scanner | [app](https://github.com/samma-io/app), [operator](https://github.com/samma-io/operator), [detect](https://github.com/samma-io/detect), [deploy](https://github.com/samma-io/deploy) |
| Kubernetes SIEM | [siem](https://github.com/samma-io/siem), [siem-rules](https://github.com/samma-io/siem-rules), [siem-storage](https://github.com/samma-io/siem-storage) |
| AWS SIEM | [aws-siem](https://github.com/samma-io/aws-siem), [vector](https://github.com/samma-io/vector), [ingester](https://github.com/samma-io/ingester), [detection-engine](https://github.com/samma-io/detection-engine), [alert-destination](https://github.com/samma-io/alert-destination), [quickwit](https://github.com/samma-io/quickwit), [grafana](https://github.com/samma-io/grafana) |

## Legacy guide

The original chapters, for the first-generation Samma on Elasticsearch and Kibana, are kept in
[`legacy/`](legacy/README.md). They are no longer maintained.
