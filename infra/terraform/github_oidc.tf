# GitHub Actions deploys the application without any stored secret.
#
# GitHub signs a short-lived token for every workflow run. AWS checks it against the
# OIDC provider below, and lets the run assume the deploy role only when the token came
# from the repository named in var.github_repository.
#
# The role can ship code and content: update the four functions, publish the dependency
# layer, sync the two buckets, invalidate CloudFront, read the SSM parameters and the
# function logs. It has no IAM permissions and no access to Terraform state, which is why
# infrastructure stays a manual terraform apply.
#
# An AWS account can hold only one OIDC provider for this URL. If the account already
# has one, set create_github_oidc_provider = false.

locals {
  github_oidc_host = "token.actions.githubusercontent.com"

  # Which workflow runs may assume the role. All three are limited to this repository.
  #   pull_request  the PR checks, which deploy to the shared dev stack and run the eval gate
  #   main branch   the release after a merge
  #   environment   a job that declares "environment: <name>" in its workflow
  github_subjects = [
    "repo:${var.github_repository}:pull_request",
    "repo:${var.github_repository}:ref:refs/heads/main",
    "repo:${var.github_repository}:environment:${var.environment}",
  ]

  account_id = data.aws_caller_identity.current.account_id
  layer_arn  = "arn:aws:lambda:${var.aws_region}:${local.account_id}:layer:${local.name}-dependencies"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://${local.github_oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1

  url = "https://${local.github_oidc_host}"
}

locals {
  github_provider_arn = (
    var.create_github_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : data.aws_iam_openid_connect_provider.github[0].arn
  )
}

data "aws_iam_policy_document" "github_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "${local.github_oidc_host}:sub"
      values   = local.github_subjects
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name                 = "${var.project_name}-${var.environment}-github-deploy"
  assume_role_policy   = data.aws_iam_policy_document.github_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "github_deploy" {
  statement {
    sid = "ShipFunctionCode"
    actions = [
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:PublishVersion",
    ]
    resources = [for function in aws_lambda_function.app : function.arn]
  }

  statement {
    sid       = "RunSetupIngestAndEvaluate"
    actions   = ["lambda:InvokeFunction"]
    resources = [for key in ["setup-db", "ingest", "evaluate"] : aws_lambda_function.app[key].arn]
  }

  statement {
    sid       = "PublishDependencyLayer"
    actions   = ["lambda:PublishLayerVersion"]
    resources = [local.layer_arn]
  }

  statement {
    sid       = "AttachDependencyLayer"
    actions   = ["lambda:GetLayerVersion"]
    resources = ["${local.layer_arn}:*"]
  }

  statement {
    sid     = "ListBuckets"
    actions = ["s3:ListBucket"]
    resources = [
      aws_s3_bucket.documents.arn,
      aws_s3_bucket.frontend.arn,
    ]
  }

  statement {
    sid     = "WriteBucketContents"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "${aws_s3_bucket.documents.arn}/*",
      "${aws_s3_bucket.frontend.arn}/*",
    ]
  }

  statement {
    sid       = "ClearCloudFrontCache"
    actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
    resources = [aws_cloudfront_distribution.app.arn]
  }

  statement {
    sid     = "ReadDeploySettings"
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter${local.ssm_prefix}",
      "arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter${local.ssm_prefix}/*",
    ]
  }

  statement {
    sid     = "ReadFunctionLogs"
    actions = ["logs:FilterLogEvents", "logs:GetLogEvents", "logs:DescribeLogStreams"]
    resources = [
      "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/lambda/${local.name}-*",
      "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/lambda/${local.name}-*:*",
    ]
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "deploy"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_deploy.json
}
