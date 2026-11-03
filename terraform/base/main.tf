# base: 作業日をまたいで残すもの。時間課金のあるリソースは置かない（NAT Gateway・VPC エンドポイントも作らない）
#   - VPC、サブネット、セキュリティグループ、シャードごとのネットワーク ACL（障害注入 F3 用）
#   - 負荷ツールのイメージ置き場（ECR）、計測結果の置き場（S3）、負荷タスクのログ（CloudWatch Logs）
# db スタックはここで作ったものを Name タグで参照する（remote state は使わない）

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  az_main    = "${var.region}a" # Writer と負荷タスクを置く AZ（AZ をまたぐと RTT が乗るため揃える）
  az_sub     = "${var.region}c" # DB サブネットグループの2つ目の AZ（要件を満たすためだけ。何も置かない）
}

# ---------------- VPC ----------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw" }
}

# 負荷タスク（Fargate）用。パブリック IP を付けて ECR・CloudWatch Logs・S3 へ直接出る。インバウンドは SG で全て閉じる
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  availability_zone       = local.az_main
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 0)
  map_public_ip_on_launch = false # run-task の assignPublicIp で付ける
  tags                    = { Name = "${var.project}-public-a", Tier = "public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${var.project}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Writer を置くプライベートサブネットはシャードごとに分ける（同じ AZ）。
# シャード単位でネットワーク ACL を掛けられるようにするため（障害注入 F3「B へのネットワーク断」）。
# SG のルール削除は確立済みの接続を切らないことがあるが、NACL はステートレスなので既存の接続も即座に止まる
resource "aws_subnet" "shard" {
  for_each          = { for i, k in var.shard_keys : k => i }
  vpc_id            = aws_vpc.main.id
  availability_zone = local.az_main
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 10 + each.value)
  tags              = { Name = "${var.project}-db-${each.key}", Tier = "db", Shard = each.key }
}

# DB サブネットグループの「2AZ 以上」を満たすための共用サブネット（インスタンスは置かない）
resource "aws_subnet" "db_sub" {
  vpc_id            = aws_vpc.main.id
  availability_zone = local.az_sub
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 20)
  tags              = { Name = "${var.project}-db-sub", Tier = "db" }
}

# プライベートサブネットはメインのルートテーブル（VPC 内のみ）をそのまま使う

# シャードごとの NACL。ルールは全許可だけを Terraform で持ち、障害注入の拒否ルールは手で足して手で消す
# （aws_network_acl に ingress/egress を書かないので、手で足したルールを Terraform は差分として扱わない）
resource "aws_network_acl" "shard" {
  for_each   = aws_subnet.shard
  vpc_id     = aws_vpc.main.id
  subnet_ids = [each.value.id]
  tags       = { Name = "${var.project}-db-${each.key}", Shard = each.key }
}

resource "aws_network_acl_rule" "shard_allow_in" {
  for_each       = aws_network_acl.shard
  network_acl_id = each.value.id
  rule_number    = 100
  egress         = false
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
}

resource "aws_network_acl_rule" "shard_allow_out" {
  for_each       = aws_network_acl.shard
  network_acl_id = each.value.id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
}

# ---------------- セキュリティグループ ----------------
resource "aws_security_group" "loadgen" {
  name        = "${var.project}-loadgen"
  description = "Fargate load generator. No inbound."
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-loadgen" }
}

resource "aws_vpc_security_group_egress_rule" "loadgen_all" {
  security_group_id = aws_security_group.loadgen.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "ECR, CloudWatch Logs, S3, Aurora"
}

resource "aws_security_group" "db" {
  name        = "${var.project}-db"
  description = "Aurora writers. MySQL from the load generator only."
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-db" }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_loadgen" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.loadgen.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  description                  = "MySQL from loadgen"
}

# ---------------- 負荷ツールのイメージ（ECR） ----------------
resource "aws_ecr_repository" "loadgen" {
  name                 = "${var.project}/loadgen"
  image_tag_mutability = "MUTABLE" # latest を上書きする運用。計測結果にはイメージのダイジェストも記録する
  force_delete         = true      # 撤収時に中身ごと消せるように
  image_scanning_configuration {
    scan_on_push = false
  }
}

resource "aws_ecr_lifecycle_policy" "loadgen" {
  repository = aws_ecr_repository.loadgen.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep last 10 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

# ---------------- 計測結果（S3） ----------------
# 負荷タスクは使い捨てなので、結果はタスクから直接ここへ上げる。db を destroy しても残る
resource "aws_s3_bucket" "results" {
  bucket        = "${var.project}-results-${local.account_id}"
  force_destroy = var.results_force_destroy # 既定 false: 中身があると base の destroy が止まる（回収忘れ防止）
}

resource "aws_s3_bucket_public_access_block" "results" {
  bucket                  = aws_s3_bucket.results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "results" {
  bucket = aws_s3_bucket.results.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "results" {
  bucket = aws_s3_bucket.results.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ---------------- 負荷タスクのログ ----------------
resource "aws_cloudwatch_log_group" "loadgen" {
  name              = "/ecs/${var.project}/loadgen"
  retention_in_days = 30
}
