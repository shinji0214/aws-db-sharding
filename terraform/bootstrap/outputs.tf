# GitHub の Secrets に登録する（アカウントIDを含むので Variables ではなく Secrets）
output "tf_state_bucket" {
  description = "Secrets: TF_STATE_BUCKET"
  value       = aws_s3_bucket.tfstate.bucket
}

output "plan_role_arn" {
  description = "Secrets: AWS_PLAN_ROLE_ARN"
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Secrets: AWS_APPLY_ROLE_ARN"
  value       = aws_iam_role.apply.arn
}
