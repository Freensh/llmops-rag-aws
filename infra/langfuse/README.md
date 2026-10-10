# The Langfuse and cache host

One 8 GiB EC2 instance running, in Docker Compose:

| Container | What it is for | Memory limit |
|---|---|---|
| `clickhouse` | Langfuse's trace store | 2.5 GiB |
| `langfuse-web` | The Langfuse screen and the API the application sends traces to | 1 GiB |
| `langfuse-worker` | Processes incoming traces | 1 GiB |
| `postgres` | Langfuse's own settings, users and prompts (not the HR database) | 0.75 GiB |
| `cache` | redis-stack: the semantic cache for answers | 0.5 GiB (data capped at 384 MB) |
| `redis` | Langfuse's internal job queue | 0.25 GiB |

The limits add up to 6 GiB. The rest is for the operating system, with 2 GiB of swap for short
spikes. Langfuse recommends 16 GiB for production, so this is a deliberately small setup: fine
for one project and a class, not for heavy traffic. A container that hits its limit is killed
and restarted by Docker on its own, instead of taking the host down.

Terraform builds all of it (`infra/terraform/langfuse.tf`). Nothing here is deployed by the
pipeline.

## How it is reached

| From | To | How |
|---|---|---|
| You | The Langfuse screen | An SSM tunnel. No port is open to the internet |
| The Lambda functions | Langfuse (port 3000) and the cache (port 6379) | Over the VPC. The host's security group allows only them |

Open the screen:

```bash
terraform output -raw langfuse_ui_tunnel      # prints a command; run it
# then open http://localhost:3000
terraform output -raw langfuse_admin_email
terraform output -raw langfuse_admin_password
```

The tunnel needs the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
for the AWS CLI. First start creates the organisation, the project, its API keys and the admin
user, and sign-up is switched off, so nobody else can create an account.

Open a shell on the host the same way, with no SSH key:

```bash
aws ssm start-session --target "$(terraform output -raw langfuse_instance_id)"
```

## First start

The first boot takes about 10 minutes: install Docker, format the data disk, pull the images,
then ClickHouse and Postgres run their migrations. To watch it from the host:

```bash
sudo tail -f /var/log/cloud-init-output.log
docker compose -f /opt/langfuse/docker-compose.yml ps
```

When every container is `healthy` or `running`, the screen answers on port 3000.

## Changing the configuration

The compose file and its config are in this folder. Terraform uploads them to S3 and the host
pulls them, so a change never replaces the instance:

```bash
terraform apply                                  # uploads the changed files
# then, on the host (through the SSM shell above):
sudo /opt/langfuse/update.sh                     # downloads them and restarts what changed
```

`update.sh` also runs at every boot.

## Backups

The data disk is snapshotted daily at 03:00 UTC, and the last seven are kept. To restore,
create a volume from a snapshot and attach it in place of the old one. Traces are the only
thing on it that cannot be rebuilt. The HR data is in Aurora, not here.

## When the memory alarm fires

The alarm triggers above 85% memory for ten minutes. On the host:

```bash
docker stats --no-stream                  # which container is using it
docker compose -f /opt/langfuse/docker-compose.yml ps
```

If ClickHouse keeps hitting its limit, either move to a larger instance
(`langfuse_instance_type`, for example `m6i.xlarge`) or reduce how much is traced. Raising a
container's limit without raising the instance only moves the problem.

## The cache

Port 6379 is the redis-stack cache. Three things to know:

- It evicts the least recently used entries when it reaches 384 MB. That is on purpose: losing
  a cached answer costs one model call and nothing else. Langfuse's own queue is a separate
  Redis that never evicts.
- The application must treat the cache as optional. If this host is down, questions are
  still answered, only slower and at full model cost.
- Traffic between the functions and the cache is not encrypted. It stays inside the VPC and
  is limited to the Lambda security group. Add TLS if that is not acceptable.

## Things to check after the first apply

- **Image tags.** Langfuse is pinned to its major version (`:4`) and redis-stack to
  `7.4.0-v3`. If a pull fails, find the tag that exists and set `REDIS_STACK_IMAGE`, or edit
  `docker-compose.yml`, then run `update.sh`.
- **S3 access.** Langfuse reaches its bucket with the instance's IAM role, with no keys. In the
  Langfuse screen, send a test trace; if the web container logs an S3 error, the role or the
  empty key settings in `docker-compose.yml` are the place to look.

## Cost

Roughly: the instance about $70 a month, the 100 GB data disk about $8, snapshots a few
dollars, and the public IPv4 address about $4. It runs all the time. Stop the instance when it
is not needed (`aws ec2 stop-instances`), or `terraform destroy`.
