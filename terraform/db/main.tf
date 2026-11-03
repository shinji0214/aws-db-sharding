# db: 作業日ごとに apply して、終わったら destroy するもの
#   - Aurora MySQL クラスタ（シャードごとに Writer 1台、Reader なし）
#   - 負荷生成の ECS クラスタとタスク定義（Fargate。測定のたびに run-task で起動し、終われば止まる）
# VPC・SG・ECR・結果バケットは base スタックのものを Name タグで参照する

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  az_main    = "${var.region}a"
  shards     = toset(var.shards)
}

# ---------------- base スタックの参照 ----------------
data "aws_vpc" "main" {
  tags = { Name = "${var.project}-vpc" }
}

data "aws_subnet" "shard" {
  for_each = local.shards
  vpc_id   = data.aws_vpc.main.id
  tags     = { Name = "${var.project}-db-${each.key}" }
}

data "aws_subnet" "db_sub" {
  vpc_id = data.aws_vpc.main.id
  tags   = { Name = "${var.project}-db-sub" }
}

data "aws_security_group" "db" {
  vpc_id = data.aws_vpc.main.id
  name   = "${var.project}-db"
}

data "aws_ecr_repository" "loadgen" {
  name = "${var.project}/loadgen"
}

data "aws_s3_bucket" "results" {
  bucket = "${var.project}-results-${local.account_id}"
}

data "aws_cloudwatch_log_group" "loadgen" {
  name = "/ecs/${var.project}/loadgen"
}

data "aws_rds_engine_version" "default" {
  engine       = "aurora-mysql"
  default_only = true
}

locals {
  engine_version = var.engine_version != "" ? var.engine_version : data.aws_rds_engine_version.default.version
}
