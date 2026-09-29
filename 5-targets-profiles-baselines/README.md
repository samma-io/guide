# 5. Targets, profiles and baselines

In chapter 4 you added a target through the dashboard. This chapter covers the ways to control
*what* gets scanned and *when*, and how to turn a pile of findings into **what changed**.

## Operator profiles

A profile is a named list of scanners. The dashboard uses `detect` (SMALL) and `all` (FULL). The
operator API and Ingress annotations accept any profile from the `scanner-profiles` ConfigMap in
`samma-io`:

| Profile | Scanners |
|---|---|
| `detect` | port, dns, http-headers, tls, traceroute, ssh-banner, whois, http-redirect |
| `dns` | dns, whois |
| `web` | http-headers, http-redirect, tls, **nikto**, nmap/http |
| `network` | port, traceroute, ssh-banner, nmap/port, nmap/tls |
| `default` | web + network + dns (no tsunami) |
| `classic` | **nikto**, nmap/port, nmap/http, nmap/tls, **tsunami** |
| `all` | everything above, including tsunami |
| `full` | nmap, nikto, tsunami, base (the first-generation scanners) |

Profiles marked in **bold** include active vulnerability probing. You can change or add profiles by
editing the ConfigMap:

```sh
kubectl -n samma-io edit configmap scanner-profiles
```

```sh
# use a profile through the operator API
curl -X PUT localhost:8080/target -H 'Content-Type: application/json' \
  -d '{"target": "example.com", "profile": "web", "scheduler": "0 6 * * *"}'
```

`scheduler` is a cron expression for the repeat scan. The default is weekly, on Sunday at 00:00.

## Targets as Kubernetes resources

The API and the dashboard both end up creating `Scanner` resources. You can also write them
yourself, one per scanner:

```yaml
apiVersion: samma.io/v1
kind: Scanner
metadata:
  name: tls-scanner-example-com
  namespace: samma-io
spec:
  target: example.com
  scanners: ["tls-scanner"]
  scheduler: "0 6 * * *"        # daily at 06:00; omit for weekly
  samma_io_id: "<dashboard target id>"   # optional: makes results show on that target's page
```

```sh
kubectl apply -f scanner.yaml
kubectl -n samma-io get sc
```

Because they are ordinary resources, you can keep them **in git** and let ArgoCD or Flux sync
them. That gives you a reviewed, versioned list of what you scan. This replaces the old "pipeline
scanner" idea from the legacy guide.

## Scan your own Ingresses automatically

The operator watches Ingresses. Annotate one and every host in its rules gets scanned:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop
  annotations:
    samma-io.alpha.kubernetes.io/enable: "true"
    samma-io.alpha.kubernetes.io/profile: "detect"       # or: scanners: "tls-scanner,http-headers-scanner"
```

Without a `profile` or `scanners` annotation, the `default` profile is used. Deleting the Ingress
removes the scanners again.

**Send discovered hosts to the dashboard.** Install the operator chart with a dashboard API token
(chapter 4, step 5). The operator then also registers each discovered host as a target in your
organisation:

```sh
helm upgrade samma-operator helm/samma-operator --reuse-values \
  --set config.apiUrl=http://samma-app.samma.svc \
  --set config.apiToken=<token> \
  --set config.profileId=<profile id, optional>
```

## Fixed scheduled scans without the operator

The [`samma-io/detect`](https://github.com/samma-io/detect) repo has a small Helm chart. It runs
the detect scanners as plain CronJobs against **fixed targets from a values file**, with no operator
and no dashboard. It is useful for a handful of known hosts:

```yaml
# my-scans.yaml
nats:
  enabled: true
  url: nats://nats.samma-io.svc:4222
scanners:
  port-scanner:  { target: example.com, schedule: "0 * * * *", env: { PORTS: "22,80,443" } }
  tls-scanner:   { target: example.com, schedule: "0 2 * * *", env: { PORT: "443" } }
  whois-scanner: { enabled: false }
```

```sh
git clone https://github.com/samma-io/detect
helm install detect detect/charts -f my-scans.yaml     # installs into samma-io
```

Some things to know about this chart:

- Set `nats.enabled: true`, or findings only go to the pod logs.
- The scanners read `PORT`. The chart's own defaults use `TLS_PORT` and `SSH_PORT`, which the
  scanners ignore, so set `PORT` yourself.
- Findings carry no dashboard target id. They land in TimescaleDB and Grafana, but not on a
  dashboard target page.

## Baselines: what changed?

A single scan tells you what is exposed today. The useful question is **what is new**: a port
that was not open last week, a certificate about to expire, a security header that disappeared.
Because every finding is kept with its timestamp in TimescaleDB, these are plain SQL queries:

```sh
kubectl -n samma-io exec -it deploy/timescaledb -- psql -U samma samma
```

**Ports open this week that were not open in the four weeks before:**

```sql
WITH recent AS (
  SELECT DISTINCT host, port FROM scan_results
  WHERE type = 'PortScan' AND status = 'open' AND time > now() - interval '7 days'),
baseline AS (
  SELECT DISTINCT host, port FROM scan_results
  WHERE type = 'PortScan' AND status = 'open'
    AND time BETWEEN now() - interval '35 days' AND now() - interval '7 days')
SELECT r.host, r.port FROM recent r
LEFT JOIN baseline b USING (host, port)
WHERE b.host IS NULL;
```

**Certificates that expire within 21 days:**

```sql
SELECT * FROM (
  SELECT DISTINCT ON (host) host, raw->>'expires' AS expires, (raw->>'days_remaining')::int AS days
  FROM   scan_results
  WHERE  type = 'TLSScan' AND raw ? 'days_remaining'
  ORDER  BY host, time DESC          -- the latest check per host
) latest
WHERE days < 21;
```

**Security headers that were present before but are missing now:**

```sql
SELECT host, raw->>'header' AS header
FROM   scan_results
WHERE  type = 'HTTPHeaders'
GROUP  BY host, raw->>'header'
HAVING bool_or((raw->>'present')::boolean) FILTER (WHERE time < now() - interval '7 days')
   AND NOT bool_or((raw->>'present')::boolean) FILTER (WHERE time > now() - interval '7 days');
```

In Grafana, add queries like these as panels on the TimescaleDB datasource, and put an **alert
rule** on each one ("fire when the query returns rows"). That turns a baseline into a notification.

## Next

That covers the scanner. The other half of Samma watches your cloud and SaaS accounts:
**[6. AWS SIEM: how the data flows](../6-aws-siem-data-flow/README.md)**.
