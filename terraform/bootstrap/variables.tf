variable "project" {
  description = "リソース名・タグの接頭辞（英小文字とハイフン）"
  type        = string
}

variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "github_repo" {
  description = "<OWNER>/<REPO>"
  type        = string
}

variable "github_owner_id" {
  description = "オーナーの数値ID。gh api repos/<OWNER>/<REPO> --jq .owner.id。空なら従来形式の sub"
  type        = string
  default     = ""
}

variable "github_repo_id" {
  description = "リポジトリの数値ID。gh api repos/<OWNER>/<REPO> --jq .id"
  type        = string
  default     = ""
}

variable "apply_environment" {
  description = "apply/destroy ジョブの GitHub Environment 名（Required reviewers を設定）"
  type        = string
  default     = "aws-apply"
}

variable "create_github_oidc_provider" {
  description = "OIDC プロバイダを作るか。アカウントに既にあれば false（1アカウント1つ）。このリポジトリでは terraform/github-oidc が持つので false"
  type        = bool
  default     = false
}

variable "apply_regional_actions" {
  description = "apply ロールに許可するリージョナルサービスのアクション"
  type        = list(string)
  # Aurora MySQL（rds）、負荷用 EC2 と VPC（ec2）、監視（logs / cloudwatch / pi）、
  # マスターパスワードを RDS 管理にする場合の Secrets Manager と KMS
  default = [
    "ec2:*", "rds:*", "logs:*", "cloudwatch:*", "pi:*",
    "ssm:GetParameter", "ssm:GetParameters",
    "secretsmanager:*", "kms:DescribeKey", "kms:CreateGrant",
  ]
}

variable "attachable_policy_arns" {
  description = "apply ロールが <project>-* ロールに付けてよい管理ポリシー"
  type        = list(string)
  default = [
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",                 # 負荷用 EC2 に Session Manager で入る
    "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole", # Aurora の拡張モニタリング
  ]
}

variable "pass_role_services" {
  description = "<project>-* ロールを渡してよいサービス"
  type        = list(string)
  default     = ["ec2.amazonaws.com", "monitoring.rds.amazonaws.com"]
}

variable "service_linked_role_services" {
  description = "初回利用時にサービスリンクロールの自動作成を許可するサービス"
  type        = list(string)
  default     = ["rds.amazonaws.com"]
}
