# ---------------- 負荷生成（ECS Fargate） ----------------
# タスクは常駐させない。scripts/loadgen.ps1 が測定のたびに run-task で起動し、測定が終わるとタスクも止まる。
# 課金はタスクが動いている秒数だけ

resource "aws_ecs_cluster" "loadgen" {
  name = "${var.project}-loadgen"
  setting {
    name  = "containerInsights"
    value = var.container_insights
  }
}

resource "aws_ecs_cluster_capacity_providers" "loadgen" {
  cluster_name       = aws_ecs_cluster.loadgen.name
  capacity_providers = ["FARGATE"] # 計測が途中で中断されないよう Spot は使わない
}

# 実行ロール: ECS がイメージ取得・ログ出力・シークレット注入に使う
data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "loadgen_execution" {
  name               = "${var.project}-loadgen-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

resource "aws_iam_role_policy_attachment" "loadgen_execution" {
  role       = aws_iam_role.loadgen_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "loadgen_execution_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [for c in aws_rds_cluster.shard : c.master_user_secret[0].secret_arn]
  }
}

resource "aws_iam_role_policy" "loadgen_execution_secrets" {
  name   = "db-master-secrets"
  role   = aws_iam_role.loadgen_execution.id
  policy = data.aws_iam_policy_document.loadgen_execution_secrets.json
}

# タスクロール: コンテナの中のスクリプトが使う（結果のアップロード、ECS Exec）
resource "aws_iam_role" "loadgen_task" {
  name               = "${var.project}-loadgen-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

data "aws_iam_policy_document" "loadgen_task" {
  statement {
    sid       = "UploadResults"
    actions   = ["s3:PutObject"]
    resources = ["${data.aws_s3_bucket.results.arn}/runs/*"]
  }
  statement {
    sid = "EcsExec"
    actions = [
      "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "loadgen_task" {
  name   = "loadgen"
  role   = aws_iam_role.loadgen_task.id
  policy = data.aws_iam_policy_document.loadgen_task.json
}

locals {
  # コンテナに渡す接続先。シャード順（a, b, c）で並べる。ID の振り分けは「id % シャード数」で決まる
  shard_list = sort(var.shards)
}

resource "aws_ecs_task_definition" "loadgen" {
  family                   = "${var.project}-loadgen"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.loadgen_cpu
  memory                   = var.loadgen_memory
  execution_role_arn       = aws_iam_role.loadgen_execution.arn
  task_role_arn            = aws_iam_role.loadgen_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64" # Graviton。イメージも arm64 でビルドする
  }

  container_definitions = jsonencode([{
    name      = "loadgen"
    image     = "${data.aws_ecr_repository.loadgen.repository_url}:${var.loadgen_image_tag}"
    essential = true
    # 既定は待機。モードや引数は run-task の overrides で渡す（scripts/loadgen.ps1）
    command = ["idle"]
    environment = [
      { name = "SHARDS", value = join(",", local.shard_list) },
      { name = "DB_HOSTS", value = join(",", [for k in local.shard_list : aws_rds_cluster.shard[k].endpoint]) },
      { name = "DB_USER", value = "admin" },
      { name = "DB_NAME", value = "lab" },
      { name = "DB_INSTANCE_CLASS", value = var.instance_class },
      { name = "DB_ENGINE_VERSION", value = local.engine_version },
      { name = "RESULTS_BUCKET", value = data.aws_s3_bucket.results.bucket },
      { name = "TASK_CPU", value = tostring(var.loadgen_cpu) },
    ]
    # シャードごとのマスターパスワード（DB_PASSWORD_A, DB_PASSWORD_B, ...）
    secrets = [for k in local.shard_list : {
      name      = "DB_PASSWORD_${upper(k)}"
      valueFrom = "${aws_rds_cluster.shard[k].master_user_secret[0].secret_arn}:password::"
    }]
    linuxParameters = { initProcessEnabled = true } # ECS Exec のため
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = data.aws_cloudwatch_log_group.loadgen.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "loadgen"
      }
    }
  }])
}
