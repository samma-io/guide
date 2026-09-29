# 2. Run a scanner locally

Every Samma scanner is a small container. It reads a target from `TARGET`, checks one thing,
prints a finding per line, and exits. You can run any of them on your laptop with nothing but
Docker. This is the quickest way to see what Samma finds, and to check a scanner fix.

## What you need

Docker. That is all.

## Run your first scanner

```sh
docker run --rm -e TARGET=scanme.nmap.org ghcr.io/samma-io/detect-port-scanner:latest
```

```
{'host': 'scanme.nmap.org', 'port': 80, 'status': 'open', 'type': 'PortScan', 'samma-io': {'scanner': 'port-scanner', 'id': '1234', 'tags': ['scanner'], 'json': '{}'}}
{'host': 'scanme.nmap.org', 'port': 443, 'status': 'closed', 'type': 'PortScan', 'samma-io': {...}}
...
{'scan': 'done', 'samma-io': {...}}
```

Each line is one **finding**:

- The scanner's own fields come first: `host`, `port`, `status` and `type`.
- The `samma-io` block comes next. It tells the platform which scanner produced the finding and
  which target it belongs to (`id`).
- The last line, `{'scan': 'done'}`, marks the end of the scan.

`scanme.nmap.org` is a host that exists to be scanned. Only point scanners at hosts you are
allowed to test.

## The scanners

All images are public, at `ghcr.io/samma-io/detect-<name>:latest`. The source is in
[`samma-io/detect`](https://github.com/samma-io/detect).

| Scanner | What it checks | `type` in findings | Extra settings |
|---|---|---|---|
| `port-scanner` | open or closed TCP ports | `PortScan` | `PORTS` (default `80,443,8080,8443`), `TIMEOUT` |
| `tls-scanner` | certificate validity, expiry, issuer, protocol, cipher | `TLSScan` | `PORT` (443), `VERIFY_CERT`, `TIMEOUT` |
| `http-headers-scanner` | security headers present or missing | `HTTPHeaders` | `HTTPS=True`, `PORT` |
| `http-redirect-scanner` | the redirect chain | `HTTPRedirect` | `MAX_REDIRECTS`, `TIMEOUT` |
| `dns-scanner` | A, AAAA, MX and TXT records | `DNSScan` | `RECORD_TYPES` |
| `ssh-banner-scanner` | SSH banner and version | `SSHBanner` | `PORT` (22), `TIMEOUT` |
| `whois-scanner` | registrar, dates, name servers | `WHOISScan` | — |
| `traceroute-scanner` | the network path to the host | `Traceroute` | `MAX_HOPS`, `TIMEOUT` |
| `waf-scanner` | which WAF or CDN is in front of the host | `WAFDetection` | `HTTPS`, `PORT`, `USER_AGENT` |

Try a few:

```sh
docker run --rm -e TARGET=example.com ghcr.io/samma-io/detect-tls-scanner:latest
docker run --rm -e TARGET=example.com -e HTTPS=True -e PORT=443 ghcr.io/samma-io/detect-http-headers-scanner:latest
docker run --rm -e TARGET=example.com ghcr.io/samma-io/detect-dns-scanner:latest
```

Look for the interesting findings with `grep`, for example the missing security headers:

```sh
docker run --rm -e TARGET=example.com ghcr.io/samma-io/detect-http-headers-scanner:latest | grep "'present': False"
```

The printed lines are Python dictionaries (single quotes), which are easy to read but are not
strict JSON. The copy a scanner sends to NATS (below) is proper JSON.

> Do not mount a host folder over `/out`. The scanner runs as a non-root user and fails with
> `Permission denied: '/out/die'`. Read the output from stdout instead.

## Settings every scanner understands

| Variable | Meaning | Default |
|---|---|---|
| `TARGET` | host name or IP to scan (required) | — |
| `SAMMA_IO_ID` | which target the finding belongs to; the platform sets it to the target's id | `1234` |
| `SAMMA_IO_TAGS` | comma-separated tags | `scanner` |
| `NATS_ENABLED` | also publish each finding to NATS | `False` |
| `NATS_URL` | NATS server | `nats://localhost:4222` |
| `NATS_SUBJECT` | NATS subject | `samma-io.scan` |

## See findings travel over NATS

In the full platform, findings do not stay on stdout. They are published to **NATS**, and a bridge
writes them into TimescaleDB. You can watch that hop locally:

```sh
docker network create samma-demo
docker run -d --rm --name nats --network samma-demo nats:2

# terminal 1: listen on the subject
docker run --rm --network samma-demo natsio/nats-box:latest \
  nats sub -s nats://nats:4222 samma-io.scan

# terminal 2: scan and publish
docker run --rm --network samma-demo -e TARGET=scanme.nmap.org \
  -e NATS_ENABLED=True -e NATS_URL=nats://nats:4222 \
  ghcr.io/samma-io/detect-dns-scanner:latest
```

Terminal 1 now prints each finding as JSON:

```
[#1] Received on "samma-io.scan"
{"host": "scanme.nmap.org","record_type": "A","samma-io": {"id": "1234", ...},"type": "DNSScan","value": "45.33.32.156"}
```

Clean up with `docker stop nats && docker network rm samma-demo`.

## Build a scanner from source

To change a scanner and test it, clone [`samma-io/detect`](https://github.com/samma-io/detect) and
use that scanner's compose file. The file builds the image, sets every variable and writes the
findings to `<scanner>/out/`:

```sh
git clone https://github.com/samma-io/detect && cd detect
mkdir -p tls-scanner/out && chmod 777 tls-scanner/out   # must exist and be writable first
docker compose -f tls-scanner/docker-compose.yaml up --build
cat tls-scanner/out/tls-scanner.json
```

Create `out/` first. If Docker creates it, root owns it and the scanner fails with
`PermissionError`. The target is set inside the compose file (`TARGET=example.com`), so edit it
there to scan something else.

## Next

Running scanners by hand is fine for a test. To scan targets on a schedule and read the results
in a dashboard, deploy the platform:
**[3. Deploy the scanner](../3-deploy-the-scanner/README.md)**.
