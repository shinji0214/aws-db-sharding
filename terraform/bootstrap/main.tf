# bootstrap: 最初に1回だけ、手元PCから管理者（Identity Center のプロファイル）で apply する。
#   - state 用 S3 バケット（ロックは use_lockfile。DynamoDB 不要）
#   - GitHub Actions の OIDC プロバイダ（アカウントに1つだけ。このリポジトリでは terraform/github-oidc が持つので参照のみ）
#   - Actions 用 IAM ロール: plan（読み取り専用・main のみ） / apply（Environment 承認済みジョブのみ）
# この state は手元PC（.gitignore 済み）。state を置くバケットを作るスタックの state はそこに置けないため。
terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  state_bucket = "${var.project}-tfstate-${local.account_id}"
  oidc_host    = "token.actions.githubusercontent.com"

  # sub の形式: 従来 repo:OWNER/REPO:...  ID 付き repo:OWNER@OWNER_ID/REPO@REPO_ID:...
  # 2026-07-15 以降に作成・改名・移管したリポジトリは ID 付き形式で発行される
  github_owner = split("/", var.github_repo)[0]
  github_name  = split("/", var.github_repo)[1]
  sub_repo = (var.github_owner_id != "" && var.github_repo_id != ""
    ? "repo:${local.github_owner}@${var.github_owner_id}/${local.github_name}@${var.github_repo_id}"
  : "repo:${var.github_repo}")

  sub_main_branch = "${local.sub_repo}:ref:refs/heads/main"
  sub_apply_env   = "${local.sub_repo}:environment:${var.apply_environment}"
}

# ---------------- state バケット ----------------
resource "aws_s3_bucket" "tfstate" {
  bucket        = local.state_bucket
  force_destroy = true # 撤収時に旧バージョンごと消せるように
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "tfstate" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.tfstate.arn, "${aws_s3_bucket.tfstate.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket     = aws_s3_bucket.tfstate.id
  policy     = data.aws_iam_policy_document.tfstate.json
  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}

# ---------------- OIDC プロバイダ（アカウントに1つ） ----------------
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_github_oidc_provider ? 1 : 0
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
  # AWS は現在この値を検証に使わないが API 上必須
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://${local.oidc_host}"
}

locals {
  oidc_provider_arn = (var.create_github_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
  : data.aws_iam_openid_connect_provider.github[0].arn)
}

data "aws_iam_policy_document" "trust" {
  for_each = {
    plan  = local.sub_main_branch
    apply = local.sub_apply_env
  }
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEqualsIgnoreCase"
      variable = "${local.oidc_host}:sub"
      values   = [each.value]
    }
  }
}

# ---------------- plan ロール（読み取り専用） ----------------
resource "aws_iam_role" "plan" {
  name                 = "${var.project}-gha-plan"
  assume_role_policy   = data.aws_iam_policy_document.trust["plan"].json
  max_session_duration = 3600
}

# ReadOnlyAccess は S3 の中身も読める。機密データのあるアカウントでは Describe/Get/List に絞る
resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ---------------- apply ロール（Environment 承認済みジョブだけ） ----------------
resource "aws_iam_role" "apply" {
  name                 = "${var.project}-gha-apply"
  assume_role_policy   = data.aws_iam_policy_document.trust["apply"].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "apply" {
  statement {
    sid       = "StateBucketList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.tfstate.arn]
  }
  statement {
    sid       = "StateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"] # *.tflock を含む
    resources = ["${aws_s3_bucket.tfstate.arn}/*"]
  }

  # プロジェクトで使うリージョナルサービス。指定リージョン以外では何もできない
  statement {
    sid       = "RegionalServices"
    actions   = var.apply_regional_actions
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  # プロジェクト名で始まる S3 バケットだけ
  statement {
    sid       = "ProjectBuckets"
    actions   = ["s3:*"]
    resources = ["arn:aws:s3:::${var.project}-*", "arn:aws:s3:::${var.project}-*/*"]
  }
  statement {
    sid       = "S3ListForProvider"
    actions   = ["s3:ListAllMyBuckets", "s3:GetBucketLocation"]
    resources = ["*"]
  }

  # IAM: 権限昇格防止。作れるのは <project>-* のロールだけ（ただし gha-* は除外）、
  # 付けられるのは許可リストの管理ポリシーだけ
  statement {
    sid = "ProjectRolesOnly"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole", "iam:UntagRole",
      "iam:UpdateRole", "iam:UpdateAssumeRolePolicy", "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
      "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.project}-*"]
  }
  statement {
    sid       = "NeverTouchGhaRoles"
    effect    = "Deny"
    actions   = ["iam:*"]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.project}-gha-*"]
  }
  statement {
    sid       = "AttachOnlyApprovedPolicies"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.project}-*"]
    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = var.attachable_policy_arns
    }
  }
  statement {
    sid = "InstanceProfiles"
    actions = [
      "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile", "iam:UntagInstanceProfile",
    ]
    resources = ["arn:aws:iam::${local.account_id}:instance-profile/${var.project}-*"]
  }
  statement {
    sid       = "PassProjectRoles"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.project}-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = var.pass_role_services
    }
  }
  statement {
    sid       = "ReadPolicies"
    actions   = ["iam:GetPolicy", "iam:GetPolicyVersion"]
    resources = ["*"]
  }
  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = var.service_linked_role_services
    }
  }
}

resource "aws_iam_role_policy" "apply" {
  name   = "${var.project}-stacks"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply.json
}
