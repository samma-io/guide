# 1a. The scanners

Samma scanners are open-source security scanners that you deploy into your own Kubernetes cluster.
Each one is a small container that checks one thing, reports what it found, and exits.

This chapter covers what each scanner does, what you use it for, and how samma.io adds external and
vendor scanners on top.

## How it works

1. **Install the operator** in your cluster (chapter 3).
2. **Annotate an Ingress.** The operator sees it and starts scanners against every host in it, from
   inside your cluster. They check TLS, security headers, open ports and OWASP-style web issues.
3. **Connect to samma.io** (optional). The operator shares your external hosts with the portal, and
   samma.io adds **external scanners** that look at them from the internet. Together they give you
   a security baseline.
4. **Tag an Ingress for compliance**, for example `pci-dss`. samma.io then runs a **validated
   vendor scanner** against that endpoint, such as a PCI DSS Approved Scanning Vendor (ASV).
5. **Read every result in your own Grafana**, inside your cluster. In-cluster, external and vendor
   findings all land in the same place, per target.
6. **Delete the Ingress and its scanners go too.** Nothing keeps scanning, or costing money, for a
   host that no longer exists.

```
 git ──► Ingress + samma annotations
              │
              ▼
          operator ──► in-cluster scanners (TLS, headers, ports, OWASP-style web checks)
              │                    │
              │ shares hosts       │
              ▼                    │
          samma.io ──► external scanners (outside-in baseline)
              │    └─► vendor scanners for tagged Ingresses (e.g. pci-dss → PCI ASV)
              │                    │
              └──────── results ───┴──► TimescaleDB in your cluster ──► your Grafana
```

### Why this matters

- **The right endpoint gets the right scanner.** The Ingress that serves card data gets the PCI
  scanner. The marketing site gets the baseline. You don't have to run every scanner on every host.
- **Mix vendors per target.** Use one vendor for some targets and another vendor for others,
  chosen per Ingress.
- **The budget follows your infrastructure.** Scanners exist as long as the Ingress does. When a
  target is gone, its scanners and their cost are gone too.
- **Everything is in git.** Scanning is set by annotations on the Ingress, so it is reviewed,
  versioned and deployed the same way as the rest of your manifests.

## In-cluster scanners

These run as Kubernetes Jobs (once, straight away) and CronJobs (repeat, weekly by default) in the
`samma-io` namespace. All of them are open source.

### Detect scanners

Lightweight Python scanners from [`samma-io/detect`](https://github.com/samma-io/detect). They are
safe to run often and make no attack-like requests.

| Scanner | What it checks | Use it for |
|---|---|---|
| `tls-scanner` | Certificate validity, expiry date and days left, issuer, protocol version, cipher | Catching expiring or invalid certificates and old TLS versions |
| `http-headers-scanner` | Security headers: HSTS, CSP, X-Frame-Options, X-Content-Type-Options, Referrer-Policy, Permissions-Policy, X-XSS-Protection | OWASP secure-headers hygiene on every web endpoint |
| `http-redirect-scanner` | The full redirect chain, hop by hop | Making sure HTTP goes to HTTPS and nothing redirects somewhere unexpected |
| `port-scanner` | Which TCP ports are open (default 80, 443, 8080, 8443) | Spotting services that should not be exposed |
| `ssh-banner-scanner` | SSH banner and software version | Finding outdated SSH servers |
| `dns-scanner` | A, AAAA, MX and TXT records | Tracking DNS changes and dangling records |
| `whois-scanner` | Registrar, creation and expiry dates, name servers | Domain expiry and ownership changes |
| `traceroute-scanner` | Network path, hop by hop | Seeing how a target is reached, and when that changes |

### Classic scanners

Well-known open-source tools wrapped in the Samma format. They go deeper, and some of them actively
probe for vulnerabilities. Only point them at hosts you are allowed to test.

| Scanner | Tool | What it checks | Use it for |
|---|---|---|---|
| `nmap/port` | [Nmap](https://nmap.org) `-sS` | Open ports, SYN scan | A thorough port inventory |
| `nmap/http` | Nmap `-sV --script http-enum` | Web server fingerprint, common paths and applications | Knowing what software you expose |
| `nmap/tls` | Nmap `--script ssl-enum-ciphers` | Every TLS cipher and protocol the server accepts, with a grade | Weak cipher and protocol findings |
| `nikto` | [Nikto](https://cirt.net/Nikto2) | Web server vulnerabilities, dangerous files, outdated software, misconfiguration | OWASP-style web application findings |
| `tsunami` | [Google Tsunami](https://github.com/google/tsunami-security-scanner) | High-severity issues: remote code execution, exposed admin UIs, weak credentials | Finding the critical issues first |

### Profiles

You rarely pick scanners one by one. A **profile** is a named group of scanners:

| Profile | Scanners | Good for |
|---|---|---|
| `detect` | all 8 detect scanners | a light, frequent check of any host |
| `web` | http-headers, http-redirect, tls, nikto, nmap/http | websites and APIs |
| `network` | port, traceroute, ssh-banner, nmap/port, nmap/tls | servers and infrastructure |
| `dns` | dns, whois | domains |
| `default` | web + network + dns (no tsunami) | used when you don't choose |
| `classic` | nikto, nmap/port, nmap/http, nmap/tls, tsunami | a deep scan |
| `all` | everything, including tsunami | maximum coverage |

Chapter 5 shows how to choose a profile on an Ingress and how to add your own.

## External scanners from samma.io

The in-cluster scanners see your hosts from inside the cluster. An attacker sees them from the
internet. When you connect the operator to samma.io with an API token, the operator shares each
Ingress host with the portal. samma.io then adds **external scanners** to that target, which scan
it from outside your network.

You get an outside-in **baseline** for every external endpoint, with no extra setup per host.

## Vendor and compliance scanners

Compliance work often needs a scanner from a specific, validated vendor. PCI DSS, for example,
requires quarterly external scans by an **Approved Scanning Vendor (ASV)**.

With samma.io you add one annotation to the Ingress:

```yaml
metadata:
  annotations:
    samma-io.alpha.kubernetes.io/enable: "true"
    samma-io.alpha.kubernetes.io/profile: "web"
    samma-io.alpha.kubernetes.io/compliance: "pci-dss"
```

samma.io then starts the validated vendor scanner for that tag against the external endpoint. Its
results come back to your Grafana next to the rest. When you delete the Ingress, the vendor scan for
it stops as well.

- **Only where it is needed.** Vendor scanners usually cost per target. Tag only the endpoints in
  scope, such as the ones in your cardholder data environment.
- **Different vendors for different targets.** The compliance tag picks the vendor. One Ingress can
  use one vendor and another Ingress a different one.
- **An audit trail in git.** Which endpoint has which compliance scanner, and since when, is in your
  git history.

The vendors themselves are connected on the samma.io side. You don't need an account with each
vendor in your cluster.

## Where results go

Every scanner writes its findings as JSON to **NATS**. A bridge stores them in **TimescaleDB** in
your cluster, and the bundled **Grafana** dashboards show them per target: overview, ports and
network, and web and TLS. Findings from external and vendor scanners are added to the same
targets. If you use the samma.io dashboard, it shows the same results for your organisation.

## Next

- Try a scanner on your laptop: **[2. Run a scanner locally](../2-run-a-scanner-locally/README.md)**
- Install it in a cluster: **[3. Deploy the scanner](../3-deploy-the-scanner/README.md)**
- Drive it from your Ingresses: **[5. Targets, profiles and baselines](../5-targets-profiles-baselines/README.md#scanning-driven-by-your-ingress)**
