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
  # Aurora MySQL（rds）、VPC（ec2）、負荷生成の ECS Fargate とイメージ置き場（ecs / ecr）、
  # 監視（logs / cloudwatch / pi）、マスターパスワードを RDS 管理にする場合の Secrets Manager と KMS
  default = [
    "ec2:*", "rds:*", "ecs:*", "ecr:*", "logs:*", "cloudwatch:*", "pi:*",
    "ssm:GetParameter", "ssm:GetParameters",
    "secretsmanager:*", "kms:DescribeKey", "kms:CreateGrant",
  ]
}

variable "attachable_policy_arns" {
  description = "apply ロールが <project>-* ロールに付けてよい管理ポリシー"
  type        = list(string)
  default = [
    "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy", # Fargate がイメージ取得・ログ出力に使う
    "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole",  # Aurora の拡張モニタリング
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",                  # 踏み台 EC2 を使う場合の Session Manager
  ]
}

variable "pass_role_services" {
  description = "<project>-* ロールを渡してよいサービス"
  type        = list(string)
  # 拡張モニタリングのロールは CreateDBInstance の中で RDS に渡すため、PassedToService は rds.amazonaws.com になる
  # （monitoring.rds.amazonaws.com は信頼ポリシー側の Principal。両方入れておく）
  default = ["ecs-tasks.amazonaws.com", "rds.amazonaws.com", "monitoring.rds.amazonaws.com", "ec2.amazonaws.com"]
}

variable "service_linked_role_services" {
  description = "初回利用時にサービスリンクロールの自動作成を許可するサービス"
  type        = list(string)
  default     = ["rds.amazonaws.com", "ecs.amazonaws.com"]
}

variable "budget_email" {
  description = "予算アラートの送り先。空なら予算を作らない（tfvars は .gitignore 済みなので公開されない）"
  type        = string
  default     = ""
}

variable "budget_limit_usd" {
  description = "月額予算（USD）。計画書の見積もりは合計約 $8"
  type        = number
  default     = 30
}
