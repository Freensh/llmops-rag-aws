# One small host for Langfuse (tracing and the prompt registry) and redis-stack (the semantic
# cache). Both run in Docker Compose on one 8 GiB instance. See ../langfuse/README.md.
#
# How it fits the rest of the stack:
#   - The host sits in a new public subnet with its own route to the internet, because it must
#     pull container images. The Lambda subnets stay private, with no route out.
#   - Nothing on the internet can connect to it. The only inbound rules allow the Lambda
#     functions, on ports 3000 (Langfuse) and 6379 (the cache). You reach the Langfuse screen
#     through an SSM Session Manager tunnel (see the langfuse_ui_tunnel output).
#   - Everything stored lives on a separate data disk that is snapshotted daily, so replacing
#     the instance does not lose traces.
#   - The compose files are uploaded to S3 here and pulled by the host, so changing the
#     configuration never replaces the instance.

locals {
  compose_version = "v2.35.1"
  langfuse_files  = toset([for file in fileset("${path.module}/../langfuse", "*") : file if file != "README.md"])
}

# ---- Network ---------------------------------------------------------------------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, 10) # 10.20.10.0/24
  availability_zone       = local.azs[0]
  map_public_ip_on_launch = false # the host asks for its address explicitly

  tags = { Name = "${local.name}-public-${local.azs[0]}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "langfuse" {
  name        = "${local.name}-langfuse"
  description = "Langfuse host: inbound from the Lambda functions only"
  vpc_id      = aws_vpc.main.id
}

locals {
  langfuse_ports = {
    langfuse = 3000 # the Langfuse API the functions send traces to
    cache    = 6379 # redis-stack, the semantic cache
  }
}

resource "aws_vpc_security_group_ingress_rule" "langfuse_from_lambda" {
  for_each = local.langfuse_ports

  security_group_id            = aws_security_group.langfuse.id
  description                  = "${each.key} from Lambda"
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  referenced_security_group_id = aws_security_group.lambda.id
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_langfuse" {
  for_each = local.langfuse_ports

  security_group_id            = aws_security_group.lambda.id
  description                  = "${each.key} on the Langfuse host"
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  referenced_security_group_id = aws_security_group.langfuse.id
}

# Outbound HTTPS only: container images, package repositories, AWS APIs
resource "aws_vpc_security_group_egress_rule" "langfuse_https" {
  security_group_id = aws_security_group.langfuse.id
  description       = "HTTPS out"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# ---- Secrets ---------------------------------------------------------------------------

resource "random_password" "langfuse" {
  for_each = toset(["nextauth", "salt", "postgres", "clickhouse", "redis", "cache", "admin"])

  length  = 32
  special = false # letters and digits only: nothing to escape in a URL or an .env file
}

resource "random_id" "langfuse_encryption" {
  byte_length = 32 # 64 hex characters, the length Langfuse requires
}

resource "random_uuid" "langfuse_public_key" {}
resource "random_uuid" "langfuse_secret_key" {}

# For the host. The keys are environment variable names: update.sh turns them into .env.
# These values are also in the Terraform state, so keep state private (see versions.tf).
resource "aws_secretsmanager_secret" "langfuse_host" {
  name                    = "${local.name}/langfuse-host"
  description             = "Passwords and keys for the Langfuse host"
  recovery_window_in_days = 0 # demo: delete at once on destroy
}

resource "aws_secretsmanager_secret_version" "langfuse_host" {
  secret_id = aws_secretsmanager_secret.langfuse_host.id
  secret_string = jsonencode({
    NEXTAUTH_SECRET                  = random_password.langfuse["nextauth"].result
    SALT                             = random_password.langfuse["salt"].result
    ENCRYPTION_KEY                   = random_id.langfuse_encryption.hex
    POSTGRES_PASSWORD                = random_password.langfuse["postgres"].result
    CLICKHOUSE_PASSWORD              = random_password.langfuse["clickhouse"].result
    REDIS_AUTH                       = random_password.langfuse["redis"].result
    CACHE_REDIS_PASSWORD             = random_password.langfuse["cache"].result
    LANGFUSE_INIT_USER_EMAIL         = var.langfuse_admin_email
    LANGFUSE_INIT_USER_PASSWORD      = random_password.langfuse["admin"].result
    LANGFUSE_INIT_PROJECT_PUBLIC_KEY = "pk-lf-${random_uuid.langfuse_public_key.result}"
    LANGFUSE_INIT_PROJECT_SECRET_KEY = "sk-lf-${random_uuid.langfuse_secret_key.result}"
  })
}

# For the application: where Langfuse and the cache are, and the keys to use them. The Lambda
# functions will read this through the Secrets Manager endpoint when tracing and caching are
# switched on in the application.
resource "aws_secretsmanager_secret" "langfuse_app" {
  name                    = "${local.name}/langfuse-app"
  description             = "How the application reaches Langfuse and the cache"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "langfuse_app" {
  secret_id = aws_secretsmanager_secret.langfuse_app.id
  secret_string = jsonencode({
    host           = "http://${aws_instance.langfuse.private_ip}:3000"
    public_key     = "pk-lf-${random_uuid.langfuse_public_key.result}"
    secret_key     = "sk-lf-${random_uuid.langfuse_secret_key.result}"
    cache_host     = aws_instance.langfuse.private_ip
    cache_port     = 6379
    cache_password = random_password.langfuse["cache"].result
  })
}

# ---- Storage ---------------------------------------------------------------------------

# Langfuse's uploads and the host's own configuration files. Replaces the MinIO container.
resource "aws_s3_bucket" "langfuse" {
  bucket_prefix = "${local.name}-langfuse-"
  force_destroy = true # demo: let `terraform destroy` delete a bucket that still has files
}

resource "aws_s3_bucket_server_side_encryption_configuration" "langfuse" {
  bucket = aws_s3_bucket.langfuse.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "langfuse" {
  bucket = aws_s3_bucket.langfuse.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# The compose file and its config. Change a file, run apply, then run update.sh on the host.
resource "aws_s3_object" "langfuse_host_files" {
  for_each = local.langfuse_files

  bucket = aws_s3_bucket.langfuse.id
  key    = "host/${each.key}"
  source = "${path.module}/../langfuse/${each.key}"
  etag   = filemd5("${path.module}/../langfuse/${each.key}")
}

# All containers keep their data on this disk, which outlives the instance
resource "aws_ebs_volume" "langfuse_data" {
  availability_zone = local.azs[0]
  size              = var.langfuse_data_gb
  type              = "gp3"
  encrypted         = true

  tags = {
    Name     = "${local.name}-langfuse-data"
    Snapshot = "langfuse" # the snapshot policy below picks volumes by this tag
  }
}

# ---- Access ----------------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "langfuse" {
  name               = "${local.name}-langfuse-host"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

# Session Manager (a shell and port forwarding with no open port) and CloudWatch metrics
resource "aws_iam_role_policy_attachment" "langfuse" {
  for_each = {
    ssm        = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    cloudwatch = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  }

  role       = aws_iam_role.langfuse.name
  policy_arn = each.value
}

data "aws_iam_policy_document" "langfuse" {
  statement {
    sid       = "ReadHostFilesAndData"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.langfuse.arn}/*"]
  }

  statement {
    sid       = "ListBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.langfuse.arn]
  }

  # Langfuse writes uploads. It cannot change the host's own configuration under host/.
  statement {
    sid     = "WriteLangfuseData"
    actions = ["s3:PutObject", "s3:DeleteObject"]
    resources = [
      "${aws_s3_bucket.langfuse.arn}/events/*",
      "${aws_s3_bucket.langfuse.arn}/media/*",
      "${aws_s3_bucket.langfuse.arn}/exports/*",
    ]
  }

  statement {
    sid       = "ReadOwnSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.langfuse_host.arn]
  }
}

resource "aws_iam_role_policy" "langfuse" {
  name   = "langfuse-host"
  role   = aws_iam_role.langfuse.id
  policy = data.aws_iam_policy_document.langfuse.json
}

resource "aws_iam_instance_profile" "langfuse" {
  name = "${local.name}-langfuse-host"
  role = aws_iam_role.langfuse.name
}

# ---- The host --------------------------------------------------------------------------

# AWS publishes the current Amazon Linux 2023 image id here
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "langfuse" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.langfuse_instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.langfuse.id]
  iam_instance_profile        = aws_iam_instance_profile.langfuse.name
  associate_public_ip_address = true # outbound only: no security group rule lets anything in
  ebs_optimized               = true

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 2          # containers sit one network hop behind the host
    http_endpoint               = "enabled"
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  # Hands the host its settings and starts the real setup, which is downloaded from S3
  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    cat > /etc/langfuse-host.env <<ENV
    BUCKET=${aws_s3_bucket.langfuse.bucket}
    REGION=${var.aws_region}
    SECRET_ID=${aws_secretsmanager_secret.langfuse_host.name}
    DATA_VOLUME_ID=${aws_ebs_volume.langfuse_data.id}
    COMPOSE_VERSION=${local.compose_version}
    ENV
    aws s3 cp "s3://${aws_s3_bucket.langfuse.bucket}/host/bootstrap.sh" /root/bootstrap.sh --region ${var.aws_region}
    sed -i 's/\r$//' /root/bootstrap.sh
    bash /root/bootstrap.sh
  EOT

  depends_on = [
    aws_s3_object.langfuse_host_files,
    aws_secretsmanager_secret_version.langfuse_host,
    aws_route_table_association.public,
    aws_iam_role_policy.langfuse,
    aws_iam_role_policy_attachment.langfuse,
  ]

  lifecycle {
    # A newer image or a changed start-up script must not replace a host that holds data.
    # Configuration changes go through S3 and update.sh instead.
    ignore_changes = [ami, user_data]
  }

  tags = { Name = "${local.name}-langfuse" }
}

resource "aws_volume_attachment" "langfuse_data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.langfuse_data.id
  instance_id = aws_instance.langfuse.id
}

# ---- Backups and alarms ----------------------------------------------------------------

data "aws_iam_policy_document" "dlm_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  name               = "${local.name}-snapshots"
  assume_role_policy = data.aws_iam_policy_document.dlm_trust.json
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

# A snapshot of the data disk every day, keeping the last seven
resource "aws_dlm_lifecycle_policy" "langfuse" {
  description        = "Daily snapshot of the Langfuse data disk"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { Snapshot = "langfuse" }

    schedule {
      name = "daily"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["03:00"]
      }

      retain_rule {
        count = 7
      }

      copy_tags = true
    }
  }
}

# The host has 8 GiB for six containers, so memory is the number to watch
resource "aws_cloudwatch_metric_alarm" "langfuse_memory" {
  alarm_name          = "${local.name}-langfuse-memory"
  alarm_description   = "The Langfuse host is using more than 85% of its memory"
  namespace           = "Northwind/Langfuse"
  metric_name         = "mem_used_percent"
  dimensions          = { InstanceId = aws_instance.langfuse.id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching" # no data at all means the agent or the host is down
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "langfuse_disk" {
  alarm_name          = "${local.name}-langfuse-disk"
  alarm_description   = "The Langfuse data disk is more than 80% full"
  namespace           = "Northwind/Langfuse"
  metric_name         = "used_percent"
  dimensions          = { InstanceId = aws_instance.langfuse.id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "langfuse_status" {
  alarm_name          = "${local.name}-langfuse-status"
  alarm_description   = "The Langfuse host failed an EC2 status check"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  dimensions          = { InstanceId = aws_instance.langfuse.id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}
