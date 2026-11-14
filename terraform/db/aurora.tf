# ---------------- Aurora MySQL（シャードごと） ----------------

# Writer は AZ-a に置きたいので、各シャードの AZ-a サブネットと、要件を満たすためだけの AZ-c サブネットを組む
resource "aws_db_subnet_group" "shard" {
  for_each   = local.shards
  name       = "${var.project}-${each.key}"
  subnet_ids = [data.aws_subnet.shard[each.key].id, data.aws_subnet.db_sub.id]
}

# db.t4g.medium では Database Insights による Performance Schema の自動管理が効かないため、手動で有効にする
# （シナリオ3のロック待ち performance_schema.data_lock_waits と、待機イベント別の DB 負荷に必要）
resource "aws_db_parameter_group" "writer" {
  name   = "${var.project}-writer"
  family = "aurora-mysql8.0"

  dynamic "parameter" {
    for_each = {
      performance_schema                                 = "1"
      performance-schema-consumer-events-waits-current   = "ON"
      performance-schema-instrument                      = "wait/%=ON"
      performance_schema_consumer_global_instrumentation = "1"
      performance_schema_consumer_thread_instrumentation = "1"
    }
    content {
      name         = parameter.key
      value        = parameter.value
      apply_method = "pending-reboot" # 静的パラメータ。作成時はそのまま反映される
    }
  }
}

resource "aws_rds_cluster" "shard" {
  for_each           = local.shards
  cluster_identifier = "${var.project}-${each.key}"
  engine             = "aurora-mysql"
  engine_version     = local.engine_version
  database_name      = "lab"
  master_username    = "admin"
  # パスワードは RDS が Secrets Manager で管理する（state に平文を残さない）
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.shard[each.key].name
  vpc_security_group_ids = [data.aws_security_group.db.id]
  storage_type           = var.storage_type
  storage_encrypted      = true

  # Database Insights は Standard（無料・7日保持）。指定しないと Advanced（有料）で作られる
  database_insights_mode                = "standard"
  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  # 作業日ごとに destroy するための設定
  deletion_protection     = false
  skip_final_snapshot     = true
  backup_retention_period = 1
  apply_immediately       = true

  lifecycle {
    ignore_changes = [availability_zones]
  }
}

resource "aws_rds_cluster_instance" "writer" {
  for_each                   = local.shards
  identifier                 = "${var.project}-${each.key}-1"
  cluster_identifier         = aws_rds_cluster.shard[each.key].id
  engine                     = aws_rds_cluster.shard[each.key].engine
  engine_version             = aws_rds_cluster.shard[each.key].engine_version
  instance_class             = var.instance_class
  availability_zone          = local.az_main
  db_parameter_group_name    = aws_db_parameter_group.writer.name
  publicly_accessible        = false
  auto_minor_version_upgrade = false
  apply_immediately          = true # パターン1b の種別変更をすぐ反映する

  monitoring_interval = var.monitoring_interval
  monitoring_role_arn = var.monitoring_interval > 0 ? aws_iam_role.rds_monitoring.arn : null

  # ロールに監視用ポリシーが付く前にインスタンスを作ると ENHANCED_MONITORING の権限不足で失敗することがある
  depends_on = [aws_iam_role_policy_attachment.rds_monitoring]
}

# Enhanced Monitoring 用ロール
data "aws_iam_policy_document" "rds_monitoring_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_monitoring" {
  name               = "${var.project}-rds-monitoring"
  assume_role_policy = data.aws_iam_policy_document.rds_monitoring_trust.json
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
