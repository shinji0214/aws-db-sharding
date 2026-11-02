terraform {
  required_version = ">= 1.10.0" # use_lockfile のため

  # bucket / key / region は init 時に -backend-config で渡す
  backend "s3" {}

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
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "db"
    }
  }
}

variable "project" {
  type = string
}

variable "region" {
  type    = string
  default = "ap-northeast-1"
}

# リソースは検証計画の合意後に追加する
