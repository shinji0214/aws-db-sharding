variable "shards" {
  description = "作る Aurora クラスタ（シャード）。パターン1・1b は [\"a\"]、パターン2は [\"a\", \"b\"]"
  type        = list(string)
  default     = ["a"]
  validation {
    condition     = length(var.shards) > 0 && alltrue([for s in var.shards : contains(["a", "b", "c"], s)])
    error_message = "shards は a / b / c から選ぶ（base スタックの shard_keys と揃える）。"
  }
}

variable "instance_class" {
  description = "Writer のインスタンス種別。パターン1bはこれを変えて apply する（変更中は数分〜十数分止まる）"
  type        = string
  default     = "db.t4g.medium"
}

variable "engine_version" {
  description = "Aurora MySQL のエンジンバージョン。空なら作成時点の既定版。Day 1 の outputs に出た値を Variables に固定して作業日をまたいで揃える"
  type        = string
  default     = ""
}

variable "storage_type" {
  description = "aurora-iopt1 = I/O-Optimized（I/O 従量課金なし）/ \"\" = Standard"
  type        = string
  default     = "aurora-iopt1"
}

variable "monitoring_interval" {
  description = "Enhanced Monitoring の間隔（秒）。0 で無効"
  type        = number
  default     = 1
}

variable "loadgen_image_tag" {
  type    = string
  default = "latest"
}

variable "loadgen_cpu" {
  description = "負荷タスクの vCPU（1024 = 1 vCPU）。旧計画の c7g.large 相当が 2048/4096"
  type        = number
  default     = 2048
}

variable "loadgen_memory" {
  type    = number
  default = 4096
}

variable "container_insights" {
  description = "負荷タスクの CPU を記録する Container Insights（enabled / enhanced / disabled）。課金はタスクが動いている間のメトリクス分だけ"
  type        = string
  default     = "enabled"
}
