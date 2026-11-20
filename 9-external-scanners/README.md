# 9. Connect external scanners

The scanners in chapters 1a–5 are Samma's own. An **external scanner** is one run by a third
party: you connect it to your organisation with the vendor's API key, point it at a group of
targets, and its runs show up next to Samma's in the dashboard. Each external scan has a price.

This is how Samma adds third-party scanners to the feed. The first one is `samma-demo`, a demo
scanner for trying out the flow; more will follow.

> **Status.** Connecting a scanner, enabling it on a profile and the scanner dashboard all work.
> External scanners are **not run yet**: the runs and costs you see for them are demo data,
> marked **Demo data** in the dashboard.

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
$5.00          × 2                      = $10.00
```

Untick it to stop. Removing a connection on the **Scanners** page also removes it from every
profile.

## Pricing

| Scanner | Price |
|---|---|
| Samma Demo Scanner (`samma-demo`) | $5.00 per scan, per target |

Every target in the profile is one scan, so each run costs the price × the number of targets.
A failed run is not charged. The price is fixed for a connection when you make it, so a later
price change applies only to new connections. Samma's own scanners have no per-scan cost.

## The scanner dashboard

**Scanners** in the dashboard lists every scanner, internal and external, with:

- **Last run**, **targets** and **runs** over the last 30 days
- **Price per scan** and **spend** over the last 30 days, for external scanners
- **Recent runs**: when each run happened, the scanner, the target (links to its results), the
  outcome, the number of findings and the cost

Internal runs come from the scan results database. Where there is none, for example on a local
development setup, they are demo data too.

## Next

External scanners will be run on the profile's schedule, with their findings landing next to the
internal scanners'. Vendor and compliance scanners are described in
[chapter 1a](../1a-the-scanners/README.md#vendor-and-compliance-scanners).
