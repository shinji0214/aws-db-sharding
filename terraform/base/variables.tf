variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "shard_keys" {
  description = "Writer 用サブネットを用意しておくシャード。db スタックの shards はこの中から選ぶ（c はシナリオ5の再配置用）"
  type        = list(string)
  default     = ["a", "b", "c"]
}

variable "results_force_destroy" {
  description = "true にすると計測結果のバケットを中身ごと destroy できる。結果を手元に回収してから切り替える"
  type        = bool
  default     = false
}
