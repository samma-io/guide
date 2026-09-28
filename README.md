# Guide to get started with Samma Scanner


## What is this
This is a guide to walk you trow the basic steps on leanring the samma scanner.
The guide also come with task and actions to performe to get a basic understading.

### After the guide you will be able to 

- Setup scans against targets
- Find result of targets and setup baselines
- Search and to advanced searches of findings
- Create dashboards

## Who is this fore ?

This is for tech user that have some basic undertdading of docker and kubernetes. But also for non techical user that can use the setup vm and want to test our the scanner.


## What you need

### Tech user
You will need some more core tools to get started like

- Minikube
- Kubctl
- Helm
- Docker


### No tech
A webbrowser is all you need




## How does it work ?
Navigates to the folder id order start with capter 1.
In there are all the steps and also the yamls you need.

## Good luck





## AWS SIEM

Chapters 8 and 9 cover the Samma AWS SIEM, an open-source SIEM that runs in your own AWS account
([`samma-io/aws-siem`](https://github.com/samma-io/aws-siem)).

- [8. How the data flows](8-aws-siem-data-flow/README.md): ingest (the ingester, and S3 → SQS → Vector), detection, alerts to Slack and GitHub, and search in Quickwit, Athena and Grafana.
- [9. Deploy your own AWS SIEM](9-aws-siem-deploy/README.md): from a clean AWS account to processing logs, including the SSM secrets for alerting and for every ingest source.

For these chapters you need an AWS account, Terraform, Docker and the AWS CLI.
