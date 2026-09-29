# 4. Your first scan

With the platform from chapter 3 running, this chapter adds a target and follows it through:
Scanner resources, scanner pods, NATS, TimescaleDB and the dashboard. There are three ways to add a
target: the dashboard, the dashboard's API with a token, or the operator API directly.

Keep these port-forwards running from chapter 3:

```sh
kubectl -n samma port-forward svc/samma-app 3000:80 &
kubectl -n samma port-forward svc/mailpit 8025:8025 &
kubectl -n samma-io port-forward svc/api 8080:8080 &
```

## 1. Sign in and create your organisation

1. Open http://localhost:3000 and choose **Sign in**.
2. The first time, you are asked for your name and an **organisation name**.
3. Open the login email: in Mailpit at http://localhost:8025, or in your real mailbox. Click the
   link.
4. You land on the dashboard. Your organisation already has a **Default** profile.

A **profile** is a set of scanners that the dashboard sends with each target:

| Profile type in the dashboard | Operator profile | Runs |
|---|---|---|
| `SMALL` (the default) | `detect` | the 8 detect scanners: port, tls, http-headers, http-redirect, dns, ssh-banner, whois, traceroute |
| `FULL` | `all` | the detect scanners **plus** nmap, nikto and tsunami |

> `FULL` runs **intrusive** tools. nikto and tsunami actively probe for vulnerabilities. Only
> use it on systems you own and have told the owners about.

## 2. Add a target

**Profiles → Default → Add target.** Enter a host name, for example `scanme.nmap.org`, and save.

The dashboard:

1. Stores the target in its own database, in your organisation.
2. Checks that it is not a private, loopback or link-local address. Those are marked **LOCAL** and
   never sent for scanning.
3. Calls `PUT http://api.samma-io.svc:8080/target` with the target, the operator profile, and
   `samma_io_id` = the target's id.
4. Marks it **DEPLOYED** when the operator accepts it.

## 3. Watch it run

```sh
kubectl -n samma-io get scanner           # one Scanner resource per scanner in the profile
kubectl -n samma-io get jobs,cronjobs     # each scanner: a Job now, plus a weekly CronJob
kubectl -n samma-io get pods -w           # scanner pods start, finish and complete
```

For each scanner in the profile, the operator creates:

- a **Job**, which scans right away;
- a **CronJob**, which scans again every week (Sunday 00:00 by default).

Read a scanner's output straight from its pod:

```sh
kubectl -n samma-io logs job/<job name>
```

Each finding is also published to NATS (`samma-io.scan`), and the bridge writes it to TimescaleDB.

## 4. Read the results

**In the dashboard.** Open the target (Profiles → Default → your target). Findings are grouped per
scanner: open ports, the TLS certificate, missing headers, DNS records, and so on. The page shows
the findings whose `samma_id` equals this target's id.

**With SQL, straight from TimescaleDB:**

```sh
kubectl -n samma-io exec -it deploy/timescaledb -- psql -U samma samma
```

```sql
-- the latest findings
SELECT time, scanner, type, host, port, status FROM scan_results ORDER BY time DESC LIMIT 20;

-- open ports per host
SELECT host, port, max(time) AS last_seen
FROM   scan_results
WHERE  type = 'PortScan' AND status = 'open'
GROUP  BY host, port ORDER BY host, port;

-- the full finding is kept as JSON
SELECT raw FROM scan_results WHERE type = 'TLSScan' ORDER BY time DESC LIMIT 1;
```

The table has the columns `time, host, port, status, type, scanner, samma_id, tags, raw (jsonb)`.
It is a TimescaleDB hypertable on `time`, so time-range queries are cheap.

**In Grafana**, if you set it up in chapter 3: see the *Samma overview* dashboard.

## 5. Add targets from a script: API tokens

For automation, create a token under **Dashboard → Tokens**. It is shown **once**; the dashboard
stores only its SHA-256 hash.

```sh
TOKEN=<your token>

# add a target (to your default profile, or pass "profileId")
curl -X POST http://localhost:3000/api/v1/targets \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"value": "example.com", "type": "dns", "label": "Main site"}'

# PUT does the same, but answers 202 if the target already exists
# remove a target
curl -X DELETE http://localhost:3000/api/v1/targets \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"value": "example.com"}'
```

`type` is `dns` for a host name or `ip` for an address. A token acts for the organisation it was
created in.

## 6. Or skip the dashboard: the operator API

The operator API works on its own, with no users and no organisations. It is useful for testing,
and for automation inside the cluster:

```sh
# scan with the detect profile
curl -X PUT localhost:8080/target -H 'Content-Type: application/json' \
  -d '{"target": "scanme.nmap.org", "profile": "detect"}'

# list targets and their Scanner resources
curl -s localhost:8080/target

# remove a target
curl -X DELETE localhost:8080/target -H 'Content-Type: application/json' \
  -d '{"target": "scanme.nmap.org"}'
```

Findings from scans started this way reach TimescaleDB and Grafana. They do **not** appear in the
dashboard, because no dashboard target has their id.

## Cleaning up a target (known issue)

Deleting a target removes its `Scanner` resources. However, the Jobs and **CronJobs of the detect
scanners are left behind**, and they keep scanning every week. Until the operator is fixed, remove
them by hand:

```sh
kubectl -n samma-io get cronjobs,jobs -o name | grep scanme-nmap-org      # the target, with dots as dashes
kubectl -n samma-io get cronjobs,jobs -o name | grep scanme-nmap-org | xargs kubectl -n samma-io delete
```

## Next

**[5. Targets, profiles and baselines](../5-targets-profiles-baselines/README.md)**: pick scanners
per target, add targets from Kubernetes and from git, and spot what changed since last week.
