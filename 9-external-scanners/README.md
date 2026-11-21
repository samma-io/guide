# 9. Connect external scanners

The scanners in chapters 1a–5 are Samma's own. An **external scanner** is one run by a third
party: you connect it to your organisation with the vendor's API key, point it at a group of
targets, and its runs show up next to Samma's in the dashboard. Each external scan has a price.

This is how Samma adds third-party scanners to the feed. The first one is `samma-demo`, a demo
scanner for trying out the flow; more will follow.

> **Status.** External scanners run for real: a new target in a profile starts a scan, and its
> result shows on the target page. `samma-demo` is backed by
> [samma-io/external-scanner](https://github.com/samma-io/external-scanner), a placeholder scanner
> that checks each target answers over HTTPS.

## 1. Connect the scanner

1. In the dashboard, open **Scanners**.
2. Under **Connect external scanners**, click **Connect scanner**.
3. Pick **Samma Demo Scanner** from the list, optionally give the connection a name, and paste
   the vendor's API key.
4. Click **Connect**.

The key is encrypted before it is stored (AES-256-GCM) and is never shown again; the dashboard
shows only its last four characters. To change a key, remove the connection and connect again.

> Self-hosting the dashboard? Set `SCANNER_SECRET_KEY` to a 32-byte base64 key
> (`openssl rand -base64 32`). Without it, the dashboard cannot store API keys.

## 2. Put the targets in a new target group

A profile is Samma's target group: every target belongs to one profile, and an external scanner
scans every target in the profiles it is enabled on.

1. Open **Profiles** and create a **new profile**, for example `External – samma-demo`.
2. Add the targets you want the external scanner to scan.

A dedicated profile keeps the cost under control: only the targets you put in it are scanned, and
so charged for. You can also enable an external scanner on an existing profile.

## 3. Enable the scanner on the profile

On the profile's page, tick the scanner under **External scanners**. The card shows what one run
costs:

```
price per scan × targets in the profile = cost per run
€1.00          × 2                      = €2.00
```

Untick it to stop. Removing a connection on the **Scanners** page also removes it from every
profile.

## 4. What happens when a target is added

```
Samma                                   external-scanner
  │  POST /scans  {target, port, samma_id}   │
  │  Authorization: Bearer <your API key>    │
  │ ───────────────────────────────────────▶ │  checks the key, makes a uuid,
  │ ◀─────────────────── 202 {uuid}          │  starts the scan in the background
  │  stores the run (uuid, when, which key)  │  … writes results/<uuid>.json
  │                                          │
  │  (someone opens the target or Scanners page)
  │  GET /scans/<uuid>                       │
  │ ───────────────────────────────────────▶ │
  │ ◀──── 200 application/json  (or 202)     │
  │  stores the result, shows it             │
```

1. You add a target to a profile with the scanner enabled (in the dashboard or with the API).
   Samma sends it to the scanner with the connection's API key. Local targets are never sent.
2. The scanner answers with a scan id; the run shows as **running**.
3. Open the target's page (or **Scanners**) once the scan is done: Samma fetches the result and
   shows it under **External scans**. Results are fetched when a page is opened, so reload to see
   a run finish.
4. **Rescan** on the target page scans it again with that scanner.

A result must be `application/json`. If it has a `findings` list, each finding (`title`,
`severity`, `detail`) is shown as a row; anything else is shown as JSON. A run that the scanner
refuses (for example a wrong API key), that reports `"status": "failed"`, or that does not finish
within 24 hours is marked **failed** and not charged.

## Pricing

| Scanner | Price |
|---|---|
| Samma Demo Scanner (`samma-demo`) | €1.00 per scan, per target |

Every target in the profile is one scan, so each run costs the price × the number of targets.
A failed run is not charged. The price is fixed for a connection when you make it, so a later
price change applies only to new connections. Samma's own scanners have no per-scan cost.

## The scanner dashboard

**Scanners** in the dashboard lists every scanner, internal and external, with:

- **Last run**, **targets** and **runs** over the last 30 days
- **Price per scan** and **spend** over the last 30 days, for external scanners
- **Recent runs**: when each run happened, the scanner, the target (links to its results), the
  outcome, the number of findings and the cost

External runs are the real runs described above. Internal runs come from the scan results
database; where there is none, for example on a local development setup, they are demo data.

## Results in your cluster

With the operator's [collector](https://github.com/samma-io/operator#collector) on, external results
come back to your cluster like Samma's own: `GET /api/v1/targets/<id>/results` lists them under the
scanner name `external:<id>` (for example `external:samma-demo`), so they show up as
`samma_findings{scanner="external:samma-demo"}` and as `samma.finding` log lines. The collector's
poll also fetches results still in progress, so nobody has to open the dashboard first. The
partner's detail text is never written to the logs.

## Run your own external scanner

```bash
git clone git@github.com:samma-io/external-scanner.git && cd external-scanner
SCANNER_API_KEY=sd_change_me docker compose up --build    # :8080
```

Connect it in **Scanners** with the same key. Where Samma calls it is set in the scanner catalog
(`apiUrl` in the app's `src/lib/external-scanners.ts`), or per environment with
`EXTERNAL_SCANNER_URL_SAMMA_DEMO`. The API is in the external-scanner README.

## Next

External scanners will also run on the profile's schedule. Vendor and compliance scanners are described in
[chapter 1a](../1a-the-scanners/README.md#vendor-and-compliance-scanners).
