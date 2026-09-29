# 7. Deploy your own AWS SIEM

This chapter takes you from an empty AWS account to a running Samma AWS SIEM that processes your
logs. Read [chapter 6](../6-aws-siem-data-flow/README.md) first if you want to understand what you
are deploying.

## What you will have at the end

- Raw log buckets and queues for your AWS logs, GitHub and your SaaS tools
- Vector, one detection engine per lane, Quickwit and Grafana running on ECS Fargate
- The ingester Lambdas pulling Slack, 1Password, Cloudflare and Google audit logs
- Alerts arriving in Slack, critical ones also as GitHub issues
- Grafana at `https://grafana.<your-domain>` and Quickwit at `https://quickwit.<your-domain>`,
  both behind your company login
- CloudWatch alarms that email you when the SIEM itself is broken

Plan for 1–2 hours the first time. Most of that is creating tokens in Slack, GitHub and your
identity provider. The Terraform apply itself takes 10–15 minutes.

## What you need

| Thing | Why |
|---|---|
| An AWS account (a dedicated "security" or "log archive" account is best) and admin credentials | to create everything |
| Terraform ≥ 1.10, Docker (with `buildx`), the AWS CLI v2, `git` | to build and deploy |
| A GitHub account with a token that has `write:packages` | to push the images to ghcr.io |
| A domain in Route 53 in the same account (or an ACM certificate) | HTTPS for Grafana and Quickwit |
| An OIDC app at your identity provider (Google, Okta, Entra ID, …) | login in front of the UIs |
| A Slack workspace where you can install an app | alerts |
| (Optional) admin access to Slack, 1Password, Cloudflare, Google Workspace / GCP | the SaaS sources |

Cost: the default setup is roughly **250–300 USD/month** before log volume, mostly Fargate.
Turning off detection engines for lanes you do not use saves about 15 USD/month each.

---

## Step 1. Get the code and build the images

There are no published releases. You build all six images yourself.

```sh
mkdir samma && cd samma
for r in aws-siem vector detection-engine alert-destination ingester quickwit grafana; do
  git clone https://github.com/samma-io/$r
done
cd aws-siem

echo "$GHCR_TOKEN" | docker login ghcr.io -u <github-user> --password-stdin
hack/build-images.sh
```

`hack/build-images.sh` runs each repository's own `make image push`. It then extracts the two
Lambda binaries (ingester and alert-destination) from their images into zips. When it finishes you
have:

```
.artifacts/alert-destination.zip
.artifacts/ingester.zip
.artifacts/image-tags.tfvars.json     # the tags you just built, for Terraform
```

Useful options:

- `--tag 2026-09-28.1` uses one tag for everything.
- `--no-push` builds locally only.
- `--registry ghcr.io/<you>` pushes to your own organisation. If you use it, also set
  `image_repository` on the modules.

Everything builds for `linux/amd64`, even on an Apple-silicon laptop.

### Private or public images?

New ghcr.io packages are **private**. Choose one of these:

- **Make them public:** GitHub → your organisation → Packages → each package → Package settings →
  Change visibility. Nothing else is needed.
- **Keep them private:** store a pull token in Secrets Manager and pass its ARN to Terraform:

  ```sh
  aws secretsmanager create-secret --name siem/ghcr \
    --secret-string '{"username":"<github-user>","password":"<token with read:packages>"}'
  ```

  Then set `ghcr_credentials_secret_arn = "<the ARN>"` in step 3.

---

## Step 2. Bootstrap the Terraform state (once per account)

```sh
cd terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars   # set region; optionally your GitHub repo for CI deploys
terraform init
terraform apply
terraform output -raw backend_config > ../examples/complete/backend.tf
```

This creates:

- a versioned, encrypted **state bucket**, using S3-native locking (no DynamoDB table needed);
- optionally, a GitHub Actions **deploy role**, with a least-privilege policy scoped to
  `<name_prefix>-*`, and a read-only **plan role** for pull requests.

---

## Step 3. Configure your deployment

```sh
cd ../examples/complete
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`. A complete minimal example:

```hcl
region      = "eu-north-1"
name_prefix = "siem"            # every resource name starts with this

# Only needed if the ghcr packages are private (step 1)
# ghcr_credentials_secret_arn = "arn:aws:secretsmanager:eu-north-1:123456789012:secret:siem/ghcr-AbCdEf"

# EVERY AWS account whose logs you expect. Records from any other account are dropped.
account_allowlist = [
  { account_id = "123456789012", name = "management" },
  { account_id = "111111111111", name = "workloads-prod" },
]

# Accounts that will replicate their CloudTrail bucket into this one (step 7)
cloudtrail_replication_source_account_ids = ["123456789012"]

github_org = "example-org"      # whose audit log streams in

# SaaS sources to pull. Leave a lane out to switch it off (step 6 sets their tokens).
ingester_lanes = {
  slack       = {}
  onepassword = {}
  # cloudflare = {
  #   INGESTER_CLOUDFLARE_ACCOUNT_ID = "0123456789abcdef0123456789abcdef"
  #   INGESTER_CLOUDFLARE_ZONE_IDS   = "abcdef0123456789abcdef0123456789"
  # }
}

# Where alerts go. Channel ids are in Slack under channel details → "Channel ID".
alert_routes_yaml = <<-EOT
  routes:
    - level: critical
      log_source: "*"
      deliveries:
        - {to: slack, target: "C0EXAMPLE1"}
        - {to: github, target: "example-org/security-alerts"}
    - level: "*"
      log_source: "*"
      deliveries:
        - {to: slack, target: "C0EXAMPLE1"}
  default:
    deliveries:
      - {to: slack, target: "C0EXAMPLE1"}
EOT

alarm_email = "security@example.com"   # where the SIEM complains when it is broken

# Web UIs
edge_mode      = "public"
domain_name    = "siem.example.com"     # gives grafana.siem.example.com and quickwit.siem.example.com
hosted_zone_id = "Z0EXAMPLE"            # Route 53 zone for that domain
```

**Save money:** set `detection_lanes = ["aws", "github", "slack"]` (for example) so you only run
engines for the lanes you actually ingest.

### The login (OIDC)

At your identity provider, create an OIDC web application with these redirect URIs:

```
https://grafana.siem.example.com/oauth2/idpresponse
https://quickwit.siem.example.com/oauth2/idpresponse
```

Restrict **who** may log in at the identity provider: the load balancer checks that a user is
authenticated, not which group they belong to. Then pass the details as an environment variable, so
the client secret never lands in a file:

```sh
export TF_VAR_oidc='{
  "issuer": "https://accounts.google.com",
  "authorization_endpoint": "https://accounts.google.com/o/oauth2/v2/auth",
  "token_endpoint": "https://oauth2.googleapis.com/token",
  "user_info_endpoint": "https://openidconnect.googleapis.com/v1/userinfo",
  "client_id": "<client id>",
  "client_secret": "<client secret>"
}'
```

> **⚠ SECURITY WARNING:** if `edge_mode = "public"` and the certificate or `oidc` settings are
> missing, Terraform still deploys. The result is an internet-facing load balancer with **plain HTTP
> and no login** in front of Quickwit, where anyone can read every log. Every plan prints
> `SECURITY WARNING: …`, and `terraform output security_warnings` lists it. Only accept that in a
> throwaway test account, or use `edge_mode = "internal"`.

---

## Step 4. Deploy

```sh
terraform init
terraform apply -var-file=../../../.artifacts/image-tags.tfvars.json
terraform output security_warnings     # must print []
```

The first apply takes 10–15 minutes. When it finishes:

```sh
terraform output urls                          # Grafana and Quickwit
terraform output secret_parameters_to_fill     # the SSM parameters for steps 5 and 6
terraform output log_source_buckets            # where to point AWS logs (step 7)
```

Opening Grafana takes two logins:

1. **Your identity provider**, enforced by the load balancer.
2. **Grafana's own login page.** Sign in as `admin`, with the password stored in Secrets Manager:

   ```sh
   aws secretsmanager get-secret-value --query SecretString --output text \
     --secret-id "$(terraform output -raw grafana_admin_password_secret_arn)"
   ```

   Then create users for your team under Administration → Users. New users are Viewers, and
   self sign-up is off.

**Confirm the alarm email.** AWS sends a subscription confirmation to `alarm_email`. Until you click
it, no alarm reaches anyone.

---

## Step 5. SSM: set up alerting (Slack and GitHub)

Terraform creates every secret as an **SSM SecureString holding the placeholder `REPLACE_ME`** and
never touches its value again. You fill in the real values, and they never go into Terraform state
or git. The services only receive the parameter *name*.

```sh
terraform output secret_parameters_to_fill
# {
#   "alert-destination/GITHUB_TOKEN"   = "/siem/alert-destination/GITHUB_TOKEN"
#   "alert-destination/SLACK_BOT_TOKEN" = "/siem/alert-destination/SLACK_BOT_TOKEN"
#   "ingester/onepassword/ONEPASSWORD_TOKEN" = "/siem/ingester/onepassword/ONEPASSWORD_TOKEN"
#   "ingester/slack/SLACK_ADMIN_TOKEN" = "/siem/ingester/slack/SLACK_ADMIN_TOKEN"
# }
```

All of them are set the same way:

```sh
aws ssm put-parameter --overwrite --type SecureString \
  --name /siem/alert-destination/SLACK_BOT_TOKEN --value 'xoxb-…'
```

### Slack bot token (alerts)

1. Go to https://api.slack.com/apps → **Create New App** → From scratch.
2. **OAuth & Permissions** → Bot Token Scopes → add **`chat:write`**.
3. Install the app to the workspace and copy the **Bot User OAuth Token** (`xoxb-…`).
4. **Invite the bot to every channel** in your routes: `/invite @<app name>` in each channel.
5. Store the token in `/siem/alert-destination/SLACK_BOT_TOKEN`.

### GitHub token (issues for critical alerts)

1. GitHub → Settings → Developer settings → **Fine-grained personal access token**, owned by a bot
   or service account.
2. Repository access: only the alerts repository (e.g. `example-org/security-alerts`).
3. Permissions: **Issues: Read and write**.
4. Create the labels the issues use. They must exist, or GitHub rejects the issue:

   ```sh
   repo=example-org/security-alerts
   gh label create detection -R $repo
   for l in informational low medium high critical; do gh label create "severity:$l" -R $repo; done
   for s in aws github dns alb slack onepassword workspace gcp cloudflare; do gh label create "source:$s" -R $repo; done
   ```

5. Store the token in `/siem/alert-destination/GITHUB_TOKEN`.

### The routing table

The routes from `alert_routes_yaml` are already in `/siem/alert-destination/ROUTES`. To change
routing later, edit `alert_routes_yaml` and re-apply. An invalid table stops the Lambda from starting,
which is deliberate: alerts are never routed with a table you did not choose.

---

## Step 6. SSM: set up the ingester sources

Each lane you listed in `ingester_lanes` needs a credential. Tokens go into SSM exactly like in
step 5. Google uses federation instead of a token.

| Lane | SSM parameter | Where the token comes from |
|---|---|---|
| `slack` | `/siem/ingester/slack/SLACK_ADMIN_TOKEN` | Slack **user** token with scope `admin` |
| `onepassword` | `/siem/ingester/onepassword/ONEPASSWORD_TOKEN` | 1Password Events API token |
| `cloudflare` | `/siem/ingester/cloudflare/CLOUDFLARE_TOKEN` | Cloudflare read-only API token |
| `google-workspace` | none | Workload Identity Federation |
| `gcp-forward` | none | Workload Identity Federation |

### Slack (access and integration logs)

1. Create a Slack app and add the **User Token Scope `admin`**. It must be a *user* token: a bot
   cannot hold `admin`.
2. Have a **Workspace Owner or Admin** install it, preferably from a dedicated admin service
   account, because the token acts as whoever installed it.
3. Copy the **User OAuth Token** (`xoxp-…`) into `/siem/ingester/slack/SLACK_ADMIN_TOKEN`.

These APIs need a paid Slack plan. `paid_only` in the logs means a free plan, and
`not_allowed_token_type` means a bot token was used.

### 1Password (Events API)

1. You need a **Business** account, as owner or administrator: Integrations → Directory → **Other**
   → Add Integration → Events Reporting.
2. Grant the token **all three feeds**: item usage, sign-in attempts and audit events. A feed that is
   missing is silently skipped.
3. Store it in `/siem/ingester/onepassword/ONEPASSWORD_TOKEN`.
4. If your account is not on the US host, add the region to the lane in `terraform.tfvars` and
   re-apply:

   ```hcl
   ingester_lanes = {
     onepassword = { INGESTER_ONEPASSWORD_BASE_URL = "https://events.ent.1password.com" }   # or events.1password.eu / .ca
   }
   ```

### Cloudflare

1. My Profile → API Tokens → **Create custom token** with these **Read** permissions, scoped to your
   account and zones:

   | Scope | Permission | Gives you |
   |---|---|---|
   | Account | Audit Logs | `audit` |
   | Account | Access: Audit Logs | `access` |
   | Account | Zero Trust | `devices` |
   | Account | Account Analytics | `gateway_dns`, `gateway_http`, `gateway_network` |
   | Zone | Analytics | `firewall` |

2. Store it in `/siem/ingester/cloudflare/CLOUDFLARE_TOKEN`.
3. Put the account id and zone ids (up to 10) in the lane settings, then re-apply:

   ```hcl
   ingester_lanes = {
     cloudflare = {
       INGESTER_CLOUDFLARE_ACCOUNT_ID = "<account id>"
       INGESTER_CLOUDFLARE_ZONE_IDS   = "<zone id>,<zone id>"
     }
   }
   ```

### Google Workspace (no secret: federation)

The ingester's AWS role proves who it is to Google, so no key is ever stored.

1. **Workload Identity pool** in a GCP project:

   ```sh
   gcloud iam workload-identity-pools create aws-siem --location=global
   gcloud iam workload-identity-pools providers create-aws aws-siem-lambda \
     --location=global --workload-identity-pool=aws-siem --account-id=<your AWS account id>
   ```

   Restrict the provider with an attribute condition to the role from
   `terraform output ingester_role_arns` (the `google-workspace` entry).
2. **Service account**, for example `audit-reader@<project>.iam.gserviceaccount.com`. Grant the
   federated principal `roles/iam.serviceAccountTokenCreator` on it, and note its numeric
   **Unique ID**.
3. **Domain-wide delegation:** in the Workspace Admin Console → Security → API controls →
   Domain-wide delegation, add that Unique ID with the scope
   `https://www.googleapis.com/auth/admin.reports.audit.readonly`.
4. **Subject:** a dedicated Workspace user with a custom admin role that has the *Reports* privilege.
5. Add the lane and re-apply:

   ```hcl
   ingester_lanes = {
     google-workspace = {
       INGESTER_GCP_WIF_AUDIENCE           = "//iam.googleapis.com/projects/<number>/locations/global/workloadIdentityPools/aws-siem/providers/aws-siem-lambda"
       INGESTER_GCP_TARGET_SERVICE_ACCOUNT = "audit-reader@<project>.iam.gserviceaccount.com"
       INGESTER_GWS_SUBJECT                = "audit-reader@example.com"
     }
   }
   ```

### GCP Cloud Audit Logs (no secret: federation plus Pub/Sub)

1. Create a Pub/Sub topic and a **pull** subscription:

   ```sh
   gcloud pubsub topics create audit-logs
   gcloud pubsub subscriptions create audit-to-siem --topic=audit-logs --ack-deadline=60
   ```

2. Create a Cloud Logging sink (organisation or project level) to that topic, with the filter
   `logName:"cloudaudit.googleapis.com"`. Grant the sink's writer identity `roles/pubsub.publisher`
   on the topic.
3. Grant the federated principal from the pool above `roles/pubsub.subscriber` on the subscription.
4. Add the lane and re-apply:

   ```hcl
   ingester_lanes = {
     gcp-forward = {
       INGESTER_GCP_WIF_AUDIENCE         = "//iam.googleapis.com/projects/<number>/locations/global/workloadIdentityPools/aws-siem/providers/aws-siem-lambda"
       INGESTER_GCP_PUBSUB_PROJECT       = "<project id>"
       INGESTER_GCP_PUBSUB_SUBSCRIPTION  = "audit-to-siem"
     }
   }
   ```

### Check that a source is working

```sh
# Did the worker run, and what did it say?
aws logs tail /aws/lambda/siem-ingester-slack-worker --since 30m

# Anything stuck?
aws sqs get-queue-attributes --attribute-names ApproximateNumberOfMessages \
  --queue-url $(aws sqs get-queue-url --queue-name siem-ingester-slack-slices-dlq --query QueueUrl --output text)

# Raw data arriving?
aws s3 ls s3://siem-slack-<acct>-<region>/slack/ --recursive | tail
```

| Log message | Meaning |
|---|---|
| `… is empty; the token has not been set` | the parameter still holds `REPLACE_ME` |
| `invalid_auth`, `401`, `credential rejected` | wrong or revoked token |
| `skip_partition` / partition parked | the token lacks the permission for that feed; it re-checks once a day |

**Old history:** new lanes start from "now". To pull the vendor's history as well, add the lane to
`ingester_backfill_lanes = ["slack"]` and re-apply. Remove it again once the history is in.

---

## Step 7. Send your AWS and GitHub logs

`terraform output log_source_buckets` lists one landing bucket per AWS log type. Each bucket is
already wired to its SQS queue and to Vector (chapter 6, section 1a). You only have to point the
producers at the buckets.

| Log | Quickest way |
|---|---|
| **CloudTrail** | Replicate your organisation-trail bucket into `terraform output cloudtrail_bucket` (the account must be in `cloudtrail_replication_source_account_ids`), or create a trail that writes to it. |
| **VPC flow logs** | List VPC ids in `vpc_flow_log_vpc_ids` and re-apply. Terraform creates the flow logs. |
| **Route 53 Resolver** | List VPC ids in `dns_query_log_vpc_ids` and re-apply. |
| **ALB access and connection logs** | In each load balancer, enable access logs and connection logs to the `alb` bucket. |
| **S3 server access logs** | Enable server access logging on a bucket, with the `s3_access` bucket as target. |
| **GitHub audit log** | GitHub org → Settings → Audit log → Log streaming → **Amazon S3** → OpenID Connect, with role `terraform output github_audit_role_arn` and bucket `siem-github-audit-<acct>-<region>`. |

Remember: **records from an account that is not in `account_allowlist` are dropped by Vector.** If a
source "works" but nothing shows up, check that first.

The step-by-step for every producer, including CLI commands and key layouts, is in
[`aws-siem/docs/aws-log-sources.md`](https://github.com/samma-io/aws-siem/blob/main/docs/aws-log-sources.md).

---

## Step 8. Verify end to end

Trigger a rule on purpose. In an allow-listed account, stop and start logging on a test trail:

```sh
aws cloudtrail stop-logging --name test-trail && aws cloudtrail start-logging --name test-trail
```

Within about 10–15 minutes, which is mostly CloudTrail's own delivery delay, you should see each step:

| Step | Check |
|---|---|
| Raw | `aws s3 ls s3://siem-cloudtrail-<acct>-<region>/AWSLogs/ --recursive \| tail` |
| Filtered | `aws s3 ls s3://$(terraform output -raw filtered_bucket)/aws/ --recursive \| tail` |
| Alert | a Slack message **CloudTrail Logging Disabled** in your channel |
| Archive | `aws s3 ls s3://siem-detections-<acct>-<region>/alerts/log_source=aws/ --recursive` |
| Search | Grafana → *Log search: IAM and privilege changes*, or Quickwit, index `logs-aws`, query `eventName:StopLogging` |
| SQL | Athena, workgroup from `terraform output athena`: `SELECT * FROM detections WHERE date = '<today>'` |

If a step is missing, look at the stage before it:

| Symptom | Look at |
|---|---|
| Raw object but nothing filtered | Vector logs (`/ecs/siem-vector`); is the account in `account_allowlist`? |
| Filtered object but no alert | the `siem-filtered-aws` queue and `/ecs/siem-detection` logs; did a rule match? |
| Alert in the queue but no Slack message | the `/aws/lambda/siem-alert-destination` logs: token set? bot invited to the channel? |
| Message in any `*-dlq` | an alarm email is on its way; the logs of that stage's reader say why |
| Nothing in Quickwit | the `siem-quickwit-<index>` queue; run the bootstrap by hand (see `quickwit/docs/operations.md`) |

---

## Day 2

- **Update a service:** pull the repo, run `hack/build-images.sh <repo>`, then re-apply with the new
  tag file. ECS rolls the service, and a changed Lambda zip redeploys automatically.
- **Your own rules:** copy `detection-engine/rules/` and add Sigma rules with a `.tests.yml` each.
  Either rebuild the detection-engine image, or set `rules_dir` to your folder.
- **Quiet the silence alarm:** once you know your normal alert volume, set
  `expected_alerts_per_day`. It then alarms when alerts stop arriving.
- **Tear down:**

  ```sh
  terraform apply   -var force_destroy_buckets=true -var-file=../../../.artifacts/image-tags.tfvars.json
  terraform destroy -var-file=../../../.artifacts/image-tags.tfvars.json
  ```

  The bootstrap state bucket is protected and stays.

## Good luck

You now have a SIEM that collects AWS, GitHub and SaaS audit logs, runs Sigma detections on
everything, alerts in Slack and GitHub, and keeps a year of searchable history.
