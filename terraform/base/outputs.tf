output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "負荷タスク（Fargate）を起動するサブネット"
  value       = aws_subnet.public.id
}

output "loadgen_security_group_id" {
  value = aws_security_group.loadgen.id
}

output "ecr_repository_url" {
  value = aws_ecr_repository.loadgen.repository_url
}

output "results_bucket" {
  value = aws_s3_bucket.results.bucket
}

output "shard_network_acl_ids" {
  description = "障害注入 F3 で拒否ルールを足す NACL"
  value       = { for k, v in aws_network_acl.shard : k => v.id }
}
