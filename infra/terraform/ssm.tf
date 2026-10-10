# SSM Parameter Store: the settings the release pipeline reads.
#
# Terraform and the pipeline never share state. This is the whole contract between
# them: Terraform writes what it built, the pipeline reads it. A rebuilt stack
# (a new CloudFront distribution id, say) reaches the pipeline on its next run with
# nothing to copy by hand. The one value the pipeline cannot read from here is the
# deploy role's ARN, because it needs the role to read anything at all. That one lives in
# a GitHub repository variable (see the github_actions_role_arn output).
#
# Nothing here is secret: names, ids and public addresses only.

locals {
  ssm_prefix = "/${var.project_name}/${var.environment}"

  ssm_parameters = merge(
    { for key, function in aws_lambda_function.app : "functions/${key}" => function.function_name },
    {
      "region"                     = var.aws_region
      "layer_name"                 = "${local.name}-dependencies"
      "documents_bucket"           = aws_s3_bucket.documents.bucket
      "frontend_bucket"            = aws_s3_bucket.frontend.bucket
      "cloudfront_distribution_id" = aws_cloudfront_distribution.app.id
      "app_url"                    = local.app_url
      "api_endpoint"               = aws_apigatewayv2_api.chat.api_endpoint

      "cognito/user_pool_id"  = aws_cognito_user_pool.main.id
      "cognito/web_client_id" = aws_cognito_user_pool_client.web.id
      "cognito/ci_client_id"  = aws_cognito_user_pool_client.ci.id
      "cognito/authority"     = "https://${aws_cognito_user_pool.main.endpoint}"
      "cognito/domain"        = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.aws_region}.amazoncognito.com"
    },
  )
}

resource "aws_ssm_parameter" "deploy" {
  for_each = local.ssm_parameters

  name  = "${local.ssm_prefix}/${each.key}"
  type  = "String"
  value = each.value
}

# The demo users' password, for the pipeline's smoke test. A SecureString, so it is stored
# encrypted and kept out of the plain settings the pipeline loads in bulk. It is the same
# demo-only password Terraform gave the Cognito users.
resource "aws_ssm_parameter" "ci_demo_password" {
  name  = "${local.ssm_prefix}/ci/demo_user_password"
  type  = "SecureString"
  value = var.demo_user_password
}
