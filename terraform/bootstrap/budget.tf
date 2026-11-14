# 予算アラート（ガードレール）。db / base を destroy しても消えないよう、手元PCで持つ bootstrap に置く。
# budget_email が空なら作らない。
#
# 📝 学習メモ: 予算はタグ Project=<project> の費用だけを見る（同じアカウントの他プロジェクトの費用を混ぜないため）。
# タグで絞るには、Billing → Cost allocation tags で `Project` を有効化しておく必要がある（反映まで最大24時間）。
# 有効化前の費用は集計されないので、構築前日までに済ませる。
resource "aws_budgets_budget" "project" {
  count        = var.budget_email == "" ? 0 : 1
  name         = "${var.project}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$${var.project}"]
  }

  dynamic "notification" {
    for_each = [50, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.budget_email]
    }
  }

  # 予測で100%を超えそうなときも早めに知らせる
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }
}
