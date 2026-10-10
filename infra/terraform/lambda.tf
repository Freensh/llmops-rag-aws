# Four Lambda functions, one zip of our code, one layer of libraries.
#
#   chat       behind API Gateway: the orchestrator that answers questions
#   ingest     S3 upload or daily schedule: load, chunk, embed, store
#   setup-db   tables, row-level security, demo data
#   evaluate   score the assistant after each change
#
# Terraform creates the functions: their role, memory, timeout, network and environment.
# It does NOT ship the application. Each function starts with a small placeholder that
# answers 503, and the release pipeline (GitHub Actions) puts the real code and the
# dependency layer in. That keeps infrastructure and deployment separate, so running
# terraform apply never rolls the code back, and a code release never needs Terraform.
#
# Why the layer is not a Terraform resource: the pipeline publishes a new layer version
# whenever lambda/requirements.txt changes, then attaches it to all four functions.

locals {
  python_runtime = "python3.12"

  # Settings every function gets
  common_env = {
    DB_HOST             = aws_rds_cluster.aurora.endpoint
    DB_NAME             = aws_rds_cluster.aurora.database_name
    DB_APP_SECRET_ARN   = aws_secretsmanager_secret.db_app.arn
    SEARCH_URL          = aws_opensearchserverless_collection.policies.collection_endpoint
    MIN_BEST_SIMILARITY = var.min_best_similarity
    MAX_GAP_FROM_BEST   = var.max_gap_from_best
    CHAT_MODEL          = var.chat_model_id
    FALLBACK_CHAT_MODEL = var.fallback_chat_model_id
    GUARDRAIL_ID        = aws_bedrock_guardrail.hr.guardrail_id
    GUARDRAIL_VERSION   = aws_bedrock_guardrail_version.hr.version
  }

  functions = {
    chat = {
      handler = "app.chat_handler.handler"
      role    = aws_iam_role.chat.arn
      timeout = 29 # API Gateway gives up at 30 seconds
      env     = local.common_env
    }
    ingest = {
      handler = "app.ingest_handler.handler"
      role    = aws_iam_role.ingest.arn
      timeout = 900
      env = {
        SEARCH_URL       = aws_opensearchserverless_collection.policies.collection_endpoint
        DOCUMENTS_BUCKET = aws_s3_bucket.documents.bucket
      }
    }
    setup-db = {
      handler = "app.setup_db_handler.handler"
      role    = aws_iam_role.setup_db.arn
      timeout = 120
      env = {
        DB_HOST             = aws_rds_cluster.aurora.endpoint
        DB_NAME             = aws_rds_cluster.aurora.database_name
        DB_APP_SECRET_ARN   = aws_secretsmanager_secret.db_app.arn
        DB_ADMIN_SECRET_ARN = local.db_admin_secret_arn
      }
    }
    evaluate = {
      handler = "app.evaluate_handler.handler"
      role    = aws_iam_role.evaluate.arn
      timeout = 900
      env     = local.common_env
    }
  }

  # Every handler module the functions point at, so each placeholder can be imported
  handler_modules = ["chat_handler", "ingest_handler", "setup_db_handler", "evaluate_handler"]

  placeholder_handler = <<-EOT
    import json


    def handler(event, context):
        body = {"detail": "Not deployed yet. Run the release workflow in GitHub Actions."}
        return {
            "statusCode": 503,
            "headers": {"content-type": "application/json"},
            "body": json.dumps(body),
        }
  EOT
}

# The placeholder code every function is created with
data "archive_file" "placeholder" {
  type        = "zip"
  output_path = "${path.module}/placeholder-function.zip"

  source {
    content  = "# placeholder\n"
    filename = "app/__init__.py"
  }

  dynamic "source" {
    for_each = local.handler_modules
    content {
      content  = local.placeholder_handler
      filename = "app/${source.value}.py"
    }
  }
}

# Create each log group ourselves, so logs are kept for 14 days instead of forever
resource "aws_cloudwatch_log_group" "lambda" {
  for_each          = local.functions
  name              = "/aws/lambda/${local.name}-${each.key}"
  retention_in_days = 14
}

resource "aws_lambda_function" "app" {
  for_each = local.functions

  function_name = "${local.name}-${each.key}"
  role          = each.value.role
  runtime       = local.python_runtime
  architectures = ["x86_64"] # the dependency layer holds Linux x86_64 wheels, so the function must match
  handler       = each.value.handler
  memory_size   = 1024
  timeout       = each.value.timeout

  filename         = data.archive_file.placeholder.output_path
  source_code_hash = data.archive_file.placeholder.output_base64sha256

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = each.value.env
  }

  tracing_config {
    mode = "Active" # X-Ray traces for every invocation
  }

  lifecycle {
    # The release pipeline owns the code and the layer. Without this, the next
    # terraform apply would put the placeholder back.
    ignore_changes = [filename, source_code_hash, layers]
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy_attachment.vpc_access,
  ]
}
