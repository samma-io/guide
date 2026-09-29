# Legacy guide (Elasticsearch / Kibana era)

These are the original chapters of this guide, kept for reference. They describe the **first
generation** of Samma. That version ran on minikube with the "highground" stack: Elasticsearch 7.16,
Kibana, Grafana on Elasticsearch, and Filebeat shipping. It used the classic scanners
`sammascanner/{nmap,nikto,tsunami,base}`.

**The current guide starts at the [top-level README](../README.md).** The current stack is:

- the operator
- the detect scanners
- NATS
- TimescaleDB
- the Samma dashboard
- the AWS SIEM

| Chapter | What it covered | Where the idea lives now |
|---|---|---|
| [1-init](1-init/README.md) | minikube + operator + highground (ES/Kibana/Grafana) | [3. Deploy the scanner](../3-deploy-the-scanner/README.md) |
| [2-adding-targets](2-adding-targets/README.md) | test targets from `samma-io/targets` | [4. Your first scan](../4-first-scan/README.md) |
| [3-first-dashbourd-notech](3-first-dashbourd-notech/README.md) | searching findings in Kibana, charting in Grafana | [4. Your first scan](../4-first-scan/README.md) (dashboard + SQL) |
| [4-adding-more-targets](4-adding-more-targets/README.md) | Scanner CRs, API, Ingress annotations | [5. Targets, profiles and baselines](../5-targets-profiles-baselines/README.md) |
| [5-monitor-the-delta-notech](5-monitor-the-delta-notech/README.md) | baselines and Grafana alerts on change | [5. Targets, profiles and baselines](../5-targets-profiles-baselines/README.md) |
| [6-localscanner](6-localscanner/README.md) | run a scanner with `docker run` | [2. Run a scanner locally](../2-run-a-scanner-locally/README.md) |
| [7-pipleline-scanner](7-pipleline-scanner/README.md) | target lists in git + CI | [5. Targets, profiles and baselines](../5-targets-profiles-baselines/README.md) |
| [scanboxes](scanboxes/README.md) | a VM with kubeadm + Samma | [3. Deploy the scanner](../3-deploy-the-scanner/README.md) |

> These chapters are **not maintained**. Parts of them no longer work:
>
> - The Kubernetes apt repository used by `scanboxes` has been shut down.
> - The `elasticsearch:` field on Scanner resources has no effect in the current operator.
> - Some screenshots and files are missing.
