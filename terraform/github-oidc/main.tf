# github-oidc: GitHub Actions の OIDC プロバイダだけを持つ、アカウント共通のスタック。
#
# なぜ分けるか:
#   OIDC プロバイダはアカウントに1つしか作れない。どこかのプロジェクトの bootstrap に持たせると、
#   その bootstrap を destroy したときに、プロバイダを使う他のプロジェクトの Actions も止まる。
#   どのプロジェクトにも属さないこのスタックに持たせれば、各プロジェクトの bootstrap は自由に作って消せる。
#
# 手元PCから管理者（Identity Center のプロファイル）で apply する。state は手元（.gitignore 済み）。
# プロバイダが既にあるアカウントでは、apply の前に terraform import で取り込む（docs/setup.md の 1）。
terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.71"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "shared"
      ManagedBy = "terraform"
      Stack     = "github-oidc"
    }
  }
}

variable "region" {
  type    = string
  default = "ap-northeast-1"
}

locals {
  oidc_host = "token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
  # AWS は現在この値を検証に使わないが API 上必須
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  lifecycle {
    # 消すと、このプロバイダを使う全プロジェクトの Actions が止まる
    prevent_destroy = true
    # 取り込み元と値が違っても作り直し・更新しない
    ignore_changes = [thumbprint_list]
  }
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}
