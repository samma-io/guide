# 3. Deploy the scanner

This chapter installs the Samma scanner platform in a Kubernetes cluster. There are two parts:

1. **The operator stack**, in namespace `samma-io`: the operator, the target API, NATS, TimescaleDB,
   the NATS → TimescaleDB bridge, and optionally Grafana dashboards.
2. **The Samma dashboard**, in namespace `samma`: the web app where users sign in, add targets and
   read results. It has its own Postgres, run by CloudNativePG.

```
 namespace samma                              namespace samma-io
 ┌──────────────────────────────┐            ┌─────────────────────────────────────────────┐
 │ samma-app (Next.js :3000)    │──PUT /target──► api :8080 ──► Scanner CRDs ──► operator │
 │ samma-pg (CNPG Postgres)     │            │                              Jobs + CronJobs │
 │   users, orgs, targets       │            │                                   │          │
 │                              │◄─read-only─│ timescaledb :5432 ◄── bridge ◄── nats :4222  │
 └──────────────────────────────┘            └─────────────────────────────────────────────┘
```

## What you need

| Thing | Notes |
|---|---|
| A Kubernetes cluster on **amd64** nodes | Any distribution. For a laptop, [k3d](https://k3d.io) or kind is fine (`k3d cluster create samma`). The operator images are amd64 only, and the chart pins pods to amd64 nodes. |
| `kubectl`, `helm` 3, `git` | |
| A default StorageClass | TimescaleDB uses a 10 Gi volume; the dashboard database uses 5 Gi. k3d and kind include one. |
| An SMTP server | The dashboard logs users in with email magic links. For testing, the steps below run Mailpit in the cluster. |
| For a public dashboard: an ingress controller and cert-manager | The chart's defaults assume Traefik and a `ClusterIssuer` named `http`. |

> **⚠ Security: read before exposing anything.**
>
> - **The operator API (`api.samma-io:8080`) has no authentication.** Anyone who reaches it can
>   start scans against any host. Keep it a `ClusterIP` service, and use `kubectl port-forward`
>   when you need it from your laptop.
> - **The dashboard does not yet verify that an organisation owns a target.** It only blocks
>   private and loopback addresses. Only give dashboard accounts to people you trust, and only add
>   targets you are allowed to scan.
> - The operator's service account is bound to **`cluster-admin`**. Give Samma its own cluster, or
>   a cluster where that is acceptable.

---

## Part 1: the operator stack

### 1.1 Install the chart

```sh
git clone https://github.com/samma-io/operator
cd operator

helm install samma-operator helm/samma-operator \
  --set timescaledb.password="$(openssl rand -hex 16)"
```

The chart creates the `samma-io` namespace and installs:

| Deployment | Image | Port | What it does |
|---|---|---|---|
| `samma-operator` | `mattiashem/samma-operator` | — | watches `Scanner` resources and Ingresses, and creates scanner Jobs and CronJobs |
| `samma-api` (Service `api`) | `sammascanner/api` | 8080 | `PUT/GET/DELETE /target`: turns a target plus a profile into `Scanner` resources |
| `nats` | `nats:2` | 4222 | the message bus that carries findings |
| `samma-bridge` | `sammascanner/bridge` | — | subscribes to `samma-io.scan` and writes into TimescaleDB |
| `timescaledb` | `timescale/timescaledb:latest-pg15` | 5432 | stores findings in the `scan_results` table (10 Gi volume) |

It also installs the `Scanner` CRD (`scanner.samma.io`, short name `sc`).

Keep the TimescaleDB password: the dashboard needs it in part 2. You can read it back later with
`helm get values samma-operator`.

### 1.2 Check it is running

```sh
kubectl -n samma-io get pods
# samma-operator-…   1/1 Running
# samma-api-…        1/1 Running
# nats-…             1/1 Running
# samma-bridge-…     1/1 Running
# timescaledb-…      1/1 Running
```

The bridge retries until TimescaleDB accepts connections, so it may restart once or twice at first.

Talk to the API from your laptop:

```sh
kubectl -n samma-io port-forward svc/api 8080:8080 &
curl -s localhost:8080/health
curl -s localhost:8080/target        # the target list; empty for now
```

### 1.3 (Optional) Grafana dashboards on TimescaleDB

If you have a Grafana, the operator repo can add a TimescaleDB datasource and three dashboards
(`samma-overview`, `samma-ports` and `samma-web-tls`) to it:

```sh
pip install requests
GRAFANA_URL=https://grafana.example.com GRAFANA_USER=admin GRAFANA_PASSWORD='…' \
TSDB_HOST=timescaledb.samma-io.svc.cluster.local TSDB_PASSWORD='<timescaledb password>' \
  python grafana/setup_grafana.py
```

Grafana must be able to reach `timescaledb.samma-io.svc`, so run Grafana in the same cluster. You
can also import `grafana/dashboard-*.json` by hand.

> Several panels are still empty. They filter on older lowercase finding types (`port`, `tls`, …),
> but the detect scanners now emit `PortScan`, `TLSScan`, and so on. These panels do work: total
> scans, unique hosts, scans over time, results by type, and latest results.

---

## Part 2: the Samma dashboard

### 2.1 Install CloudNativePG

The dashboard's own database is a CloudNativePG `Cluster` (TimescaleDB-HA image). Install the
operator once per cluster:

```sh
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace
kubectl -n cnpg-system rollout status deploy/cnpg-cloudnative-pg
```

### 2.2 An SMTP server (Mailpit, for testing)

Users sign in with a magic link sent by email. For a test setup, run Mailpit. It accepts all mail
and shows it in a web UI:

```sh
kubectl create namespace samma
kubectl -n samma create deployment mailpit --image=axllent/mailpit
kubectl -n samma set env deployment/mailpit MP_SMTP_AUTH_ACCEPT_ANY=1 MP_SMTP_AUTH_ALLOW_INSECURE=1
kubectl -n samma create service clusterip mailpit --tcp=1025:1025 --tcp=8025:8025
```

In production, use your real SMTP relay instead.

### 2.3 The app secret

The chart reads its configuration from a secret named `samma-app-secrets`. `DATABASE_URL` is
**not** in it: CloudNativePG creates that one.

```sh
kubectl -n samma create secret generic samma-app-secrets \
  --from-literal=NEXTAUTH_URL="http://localhost:3000" \
  --from-literal=NEXTAUTH_SECRET="$(openssl rand -base64 32)" \
  --from-literal=EMAIL_SERVER_HOST="mailpit.samma.svc" \
  --from-literal=EMAIL_SERVER_PORT="1025" \
  --from-literal=EMAIL_SERVER_USER="samma" \
  --from-literal=EMAIL_SERVER_PASSWORD="samma" \
  --from-literal=EMAIL_FROM="Samma <noreply@example.com>" \
  --from-literal=EMAIL_SERVER_SECURE="false" \
  --from-literal=EMAIL_TLS_REJECT_UNAUTHORIZED="false" \
  --from-literal=OPERATOR_API_URL="http://api.samma-io.svc:8080" \
  --from-literal=SCANNER_DATABASE_URL="postgresql://samma:<timescaledb password>@timescaledb.samma-io.svc:5432/samma"
```

| Key | What it is |
|---|---|
| `NEXTAUTH_URL` | The URL users open the dashboard on. It must match, or login links break. Use `http://localhost:3000` with port-forward, or `https://<your host>` behind an ingress. |
| `NEXTAUTH_SECRET` | A random session-signing key. |
| `EMAIL_*` | The SMTP server for the login emails. |
| `OPERATOR_API_URL` | Where the dashboard sends targets. Without it, targets stay `READY_TO_DEPLOY` and never scan. |
| `SCANNER_DATABASE_URL` | Read-only access to the findings in TimescaleDB. Without it, the result pages are empty. |

> The chart's `values.yaml` comment shows `OPERATOR_API_URL=…operator…:5000`. That is out of
> date. The API service is `api.samma-io.svc` on port **8080**.

### 2.4 Install the app chart

The chart lives in the app repo. There is no `latest` image tag, so pin a tag. The one currently
deployed is recorded in [`samma-io/deploy`](https://github.com/samma-io/deploy):

```sh
git clone https://github.com/samma-io/app
TAG=$(curl -s https://raw.githubusercontent.com/samma-io/deploy/main/app/deploy.yaml \
      | grep -o 'ghcr.io/samma-io/app:[a-z0-9]*' | head -1 | cut -d: -f2)

helm install samma-app app/chart -n samma \
  --set image.tag="$TAG" \
  --set ingress.enabled=false
```

What happens next:

1. CloudNativePG creates the database cluster `samma-pg`, and the secret `samma-pg-app` holding its
   URI.
2. The app pod's init container waits for the database, then runs `prisma migrate deploy`.
3. The app starts on port 3000.

```sh
kubectl -n samma get cluster,pods
kubectl -n samma port-forward svc/samma-app 3000:80 &
kubectl -n samma port-forward svc/mailpit 8025:8025 &
```

Open http://localhost:3000. Your login emails appear in Mailpit at http://localhost:8025.

**Public install.** Leave `ingress.enabled=true` and set your own hosts, TLS and issuer in a
values file (see `app/chart/values.yaml`). Set `NEXTAUTH_URL` to `https://<your host>`.

**GitOps.** For samma.io itself the app is deployed by ArgoCD from
[`samma-io/deploy`](https://github.com/samma-io/deploy). `base/app.yaml` is the ArgoCD
`Application`, and `app/deploy.yaml` is the rendered chart, which the app's CI updates on each
build. The operator stack is not in that repo; it is installed with Helm as in part 1.

---

## Checklist

- [ ] `kubectl -n samma-io get pods`: five pods are Running.
- [ ] `curl localhost:8080/health` (through port-forward) answers.
- [ ] `kubectl -n samma get cluster samma-pg` reports a healthy cluster.
- [ ] http://localhost:3000 loads, and a login email arrives in Mailpit.

## Next

**[4. Your first scan](../4-first-scan/README.md)**: sign in, add a target, and watch it get scanned.
