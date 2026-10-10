# Values printed after `terraform apply`. The guide's deploy steps use them.
# Read one with:  terraform output -raw app_url

output "app_url" {
  description = "Open this in a browser. Your own domain if you set one, otherwise the CloudFront address."
  value       = local.app_url
}

output "cloudfront_domain" {
  description = "The distribution's own address. Still works when a custom domain is configured."
  value       = "https://${aws_cloudfront_distribution.app.domain_name}"
}

output "certificate_arn" {
  description = "The wildcard certificate CloudFront is using, if any"
  value       = local.use_custom_domain ? local.certificate_arn : "none (using the CloudFront certificate)"
}

output "documents_bucket" {
  description = "Upload the policy files and manifest.json here"
  value       = aws_s3_bucket.documents.bucket
}

output "frontend_bucket" {
  description = "Upload the built React app (frontend/dist) here"
  value       = aws_s3_bucket.frontend.bucket
}

output "cloudfront_distribution_id" {
  description = "Needed to clear the CloudFront cache after uploading a new front end"
  value       = aws_cloudfront_distribution.app.id
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "function_names" {
  value = { for key, function in aws_lambda_function.app : key => function.function_name }
}

output "api_endpoint" {
  description = "API Gateway's own address (the app uses it through CloudFront)"
  value       = aws_apigatewayv2_api.chat.api_endpoint
}

# Paste this into frontend/.env.production before `npm run build`. These values are public.
output "frontend_env" {
  value = <<-EOT
    VITE_AUTH_MODE=cognito
    VITE_COGNITO_AUTHORITY=https://${aws_cognito_user_pool.main.endpoint}
    VITE_COGNITO_CLIENT_ID=${aws_cognito_user_pool_client.web.id}
    VITE_COGNITO_DOMAIN=https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.aws_region}.amazoncognito.com
  EOT
}

output "github_actions_role_arn" {
  description = "Set this as the repository variable AWS_ROLE_ARN in GitHub. It is the only value the pipeline cannot read from SSM."
  value       = aws_iam_role.github_deploy.arn
}

output "ssm_prefix" {
  description = "Where the pipeline reads the rest of its settings from"
  value       = local.ssm_prefix
}

output "langfuse_instance_id" {
  description = "The Langfuse and cache host"
  value       = aws_instance.langfuse.id
}

output "langfuse_private_ip" {
  description = "Where the Lambda functions reach Langfuse (port 3000) and the cache (port 6379)"
  value       = aws_instance.langfuse.private_ip
}

output "langfuse_ui_tunnel" {
  description = "Run this, then open http://localhost:3000. Needs the Session Manager plugin for the AWS CLI."
  value       = "aws ssm start-session --target ${aws_instance.langfuse.id} --document-name AWS-StartPortForwardingSession --parameters portNumber=3000,localPortNumber=3000 --region ${var.aws_region}"
}

output "langfuse_admin_email" {
  value = var.langfuse_admin_email
}

output "langfuse_admin_password" {
  description = "Sign in to Langfuse with langfuse_admin_email and this password"
  value       = random_password.langfuse["admin"].result
  sensitive   = true
}
