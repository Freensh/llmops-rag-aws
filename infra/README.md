# infra

Everything that creates AWS resources. Two ways to build the same thing.

| | |
|---|---|
| **[../docs/console-build-guide.md](../docs/console-build-guide.md)** | Build it by hand in the AWS Console. Every service, every setting, and why. |
| **[terraform/](terraform)** | Build the identical stack in one command. About twenty minutes, most of it waiting for Aurora and CloudFront. |

Do the console walkthrough once. You cannot debug a Terraform stack you have never seen the
inside of, and half the hard questions about this architecture are about the parts
Terraform hides from you. Then use Terraform for every build after that, because doing it by
hand twice teaches you nothing new.

Neither path contains application code. The code is in [`lambda/`](../lambda) and reaches AWS
through the release pipeline (GitHub Actions), not through Terraform. Terraform builds the
stack and leaves each Lambda function with a placeholder that answers 503 until the first
release. That split is deliberate: running `terraform apply` never rolls the code back, and
a code release never needs Terraform.

## Layout

```
infra/
  terraform/       one file per service

docs/
  console-build-guide.md   the console walkthrough
```

`terraform/` is its own folder because Terraform uses its directory as a working directory:
`terraform init` puts several hundred megabytes of provider binaries in `.terraform/`, and
your state file, lock file and `terraform.tfvars` all live beside the `.tf` files. Keeping
that out of the way means `infra/` stays readable.

## The Terraform path

Infrastructure is applied by hand from your own machine. The pipeline never runs Terraform.

```bash
# 1. Settings
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
# set at least: cognito_domain_prefix and github_repository (OWNER/REPO)
# set create_github_oidc_provider = false if the account already has a GitHub OIDC provider

# 2. Build
terraform init
terraform plan
terraform apply

# 3. Give GitHub the one value it cannot look up for itself: the deploy role
terraform output -raw github_actions_role_arn
```

In the GitHub repository, go to Settings > Secrets and variables > Actions > Variables and add:

| Variable | Value |
|---|---|
| `AWS_ROLE_ARN` | the output of `github_actions_role_arn` |
| `AWS_REGION` | the region you applied in |
| `ENVIRONMENT` | `dev` (the `environment` value in `terraform.tfvars`) |

Nothing else is stored in GitHub, and there are no secrets. Every other value (function names,
buckets, CloudFront ID, Cognito IDs, app URL) is read by the workflows from SSM Parameter Store
under `/<project_name>/<environment>/`, where Terraform wrote it. List them with:

```bash
aws ssm get-parameters-by-path --path "$(terraform output -raw ssm_prefix)" --recursive
```

Then run the release workflow (Actions > Release > Run workflow). It publishes the dependency
layer, ships the function code, creates the tables and demo data, loads the documents,
builds and publishes the React app, clears the CloudFront cache and checks the stack
answers. Until the first release finishes, the app answers 503. The workflows, the
branch protection to turn on and the scripts behind each step are in
[../docs/pipeline.md](../docs/pipeline.md).

Tear it down with `terraform destroy`. Then check Resource Groups > Tag Editor for
`Project = northwind-hr` across all regions: it should come back empty. The dependency layer
is created by the pipeline, so Terraform does not know about it. Delete its versions by hand
(Lambda > Layers > `northwind-hr-dependencies`).

### Terraform state

State is kept locally in `infra/terraform/terraform.tfstate`. It contains secrets (database
and demo user passwords), so it is gitignored and must never be committed. Back it up after
every `apply`. Losing it means Terraform no longer knows what it built. To move to a shared
backend later, uncomment the `backend` block in `versions.tf` and run `terraform init -migrate-state`.

### What the pipeline is allowed to do

The `github_actions_role_arn` role can update the four functions, publish the layer, write to
the two buckets, invalidate CloudFront, read the SSM parameters and read the function logs.
It has no IAM permissions and cannot touch Terraform state. It can be assumed only by workflow
runs from the repository in `github_repository`: pull requests, the `main` branch, and jobs
that use the environment named in `environment`.

## What is in each file

| File | What it creates |
|---|---|
| `network.tf` | VPC, two private subnets, route table. No internet gateway, no NAT. |
| `security_groups.tf` | Three firewalls: Lambda, Aurora, VPC endpoints |
| `endpoints.tf` | Private routes to Bedrock, Secrets Manager and S3 |
| `aurora.tf` | Aurora PostgreSQL Serverless v2, minimum 0 ACUs |
| `secrets.tf` | The `hr_app` credentials (the master password is managed by RDS) |
| `opensearch.tf` | NextGen Serverless collection group and collection, and its access policies |
| `s3.tf` | The documents bucket (versioned) and the front-end bucket (private) |
| `bedrock.tf` | The guardrail, and a numbered version of it |
| `iam.tf` | One role per function, each with only what that function does |
| `lambda.tf` | The four functions, created with a placeholder. The pipeline owns their code and layer. |
| `ingestion_triggers.tf` | S3 notification on `manifest.json`, plus a daily EventBridge rule |
| `api_gateway.tf` | HTTP API, routes, Cognito JWT authorizer, throttling |
| `cognito.tf` | User pool, web app client, a password-auth client for CI, demo users |
| `cloudfront.tf` | One HTTPS address for the app and the API |
| `waf.tf` | Managed rule sets and a per-IP rate limit |
| `dns.tf` | Route 53 records and the wildcard ACM certificate (optional) |
| `monitoring.tf` | Alarms for errors, 5xx responses and slow answers |
| `github_oidc.tf` | The GitHub OIDC provider and the deploy role the workflows assume |
| `ssm.tf` | The SSM parameters the workflows read |
| `outputs.tf` | The values you need after `apply`, including the role ARN |

## Settings worth knowing

Set these in `terraform.tfvars`:

| Variable | Default | Why you would change it |
|---|---|---|
| `cognito_domain_prefix` | none, required | Must be unique in the region. Add your initials. |
| `domain_name` | `""` | Your domain, if its hosted zone is in this account. Empty means the CloudFront address. |
| `subdomain` | `hrassistant` | The app ends up at `https://<subdomain>.<domain_name>` |
| `aurora_instance_count` | 2 | 1 halves the database cost and gives up Multi-AZ failover |
| `environment` | `dev` | Used in tags, the SSM path and the deploy role name. Resource names do not change. |
| `github_repository` | none, required | `OWNER/REPO`. Only this repository can assume the deploy role. |
| `create_github_oidc_provider` | `true` | An account can hold one provider for GitHub. Set `false` if it already exists. |
| `demo_user_password` | `Northwind-Demo-2026!` | Password of the demo users. Demo only, and it is stored in state. |
| `alarm_email` | `""` | Where CloudWatch alarms go. AWS sends a confirmation first. |
| `min_best_similarity` | `0.25` | The relevance cut-off. Measure it for your corpus rather than guessing. |

## Two things to get right

**OpenSearch must be NextGen.** `opensearch.tf` creates a collection group with
`generation = "NEXTGEN"` and a minimum of 0 OCUs, so an idle collection costs a few dollars a
month. A Classic collection bills a 2 OCU minimum around the clock, about $350 a month,
whether or not anybody uses it. This needs AWS provider 6.49 or newer.

**The certificate must be in us-east-1.** CloudFront reads certificates only from us-east-1,
whatever region the rest of the stack runs in. `dns.tf` uses the `aws.us_east_1` provider
alias for exactly this reason.
