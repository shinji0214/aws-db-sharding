# github-oidc: GitHub Actions の OIDC プロバイダだけを持つ、アカウント共通のスタック。
#
# なぜ分けるか:
#   OIDC プロバイダはアカウントに1つしか作れない。今はハニーポット検証の bootstrap が持っているため、
#   そちらを destroy するとこのリポジトリの Actions も止まる。プロバイダをどのプロジェクトにも属さない
#   このスタックへ移しておけば、各プロジェクトの bootstrap は自由に作って消せる。
#
# 手元PCから管理者（Identity Center のプロファイル）で apply する。state は手元（.gitignore 済み）。
# 既存のプロバイダは下の import ブロックで取り込む（作り直さないので Actions は止まらない）。
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

data "aws_caller_identity" "current" {}

locals {
  oidc_host = "token.actions.githubusercontent.com"
}

# 既存プロバイダの取り込み。プロバイダが無い新しいアカウントで使うときは、このブロックを消して apply する
import {
  to = aws_iam_openid_connect_provider.github
  id = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_host}"
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
