# The deployment pipeline

Infrastructure is applied by hand with Terraform. Everything that changes the running
application goes through GitHub Actions. This page covers the one-time setup, what each
workflow does, and which manual step each part of the pipeline replaces.

## One-time setup

1. Apply the infrastructure ([infra/README.md](../infra/README.md)). Note the role ARN:
   `terraform output -raw github_actions_role_arn`.
2. In GitHub, open Settings > Secrets and variables > Actions > **Variables** and add
   `AWS_ROLE_ARN`, `AWS_REGION` and `ENVIRONMENT` (`dev`). There are no secrets to add.
3. In Settings > Branches, add a protection rule for `main`:
   - Require a pull request before merging
   - Require review from Code Owners (the owners are in `.github/CODEOWNERS`)
   - Require status checks to pass: `checks` and `deploy` from the Pull request workflow
4. Run the first release: Actions > Release > Run workflow. Until it finishes the app
   answers 503, because Terraform only creates the functions with a placeholder.

## What runs when

| Event | Workflow | What happens |
|---|---|---|
| Pull request | `pr.yml` | Lint, offline tests, shell and Terraform checks, then a full deploy to dev (from branches in this repository only) |
| Merge to `main` | `release.yml` | The same deploy to dev. Changes that touch only `docs/`, `infra/` or Markdown are skipped |
| Run by hand | `release.yml` | Same deploy, with two switches: rebuild the layer, re-ingest the documents |

Both call `deploy.yml`, so a pull request and a release run the same steps. There is one dev
stack, so deploys queue: a second run waits for the first.

## The deploy steps

Each step is a script in `scripts/ci/` that you can also run by hand, with the same
environment variables.

| Step | Script | What it does |
|---|---|---|
| Read settings | `load-settings.sh` | Reads every parameter under `/northwind-hr/<environment>/` in SSM |
| Layer | `publish-layer.sh` | Builds and publishes the dependency layer only when `lambda/requirements.txt` changed |
| Code | `deploy-functions.sh` | Attaches the layer and uploads the code to the four functions, waiting for each |
| Database | `migrate.sh` | Runs `setup-db`, retrying while Aurora wakes up |
| Documents | `sync-documents.sh` | Uploads the documents, then the manifest, only when their content changed, and waits for ingestion |
| Web app | `publish-frontend.sh` | Builds React with the Cognito settings, copies it to S3, clears CloudFront |
| Smoke test | `smoke-test.sh` | Checks the API refuses a request with no token, signs in as a demo user, asks one question (this also wakes Aurora and OpenSearch) |
| Evaluation | `run-evaluation.sh` | Runs the golden questions. For now a failure is reported but does not fail the run |

## What it replaces

| Manual step in the old guide | Now |
|---|---|
| `bash scripts/build-layer.sh` before `terraform apply` | Not needed for `apply`. The layer is published by the pipeline |
| `bash scripts/build-function.sh` and `deploy-code.sh` | `deploy-functions.sh` |
| Invoke `setup-db` | `migrate.sh` |
| Upload documents, then the manifest | `sync-documents.sh` |
| Write `.env.production`, build, sync, invalidate | `publish-frontend.sh` |
| Set each demo user's password with `admin-set-user-password` | Terraform sets it (`demo_user_password`) |
| The first question hangs while Aurora wakes | `smoke-test.sh` asks it once, with retries |
| Run the evaluation by hand | `run-evaluation.sh` |

## Still manual

- `terraform apply` and `destroy`, and backing up the local state file
- One-time Bedrock access for a Claude model, if you want one
- Reading the guardrail in the console, tuning `min_best_similarity`, and the prompt
  injection exercises in the deployment guide
- Deleting old layer versions after a `destroy` (the pipeline owns them, not Terraform)

## Known limits

- `setup-db` runs the SQL only on an empty database. A change to `lambda/db/*.sql` does not
  reach an existing one until a migration tool replaces it.
- Dev holds whichever run finished last, including a pull request that failed the
  evaluation. Merging fixes it.
- Pull requests can edit their own workflow and the role they use can update dev. That is why
  `.github/`, `infra/` and `scripts/` have code owners.
