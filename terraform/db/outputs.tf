output "engine_version" {
  description = "作業日をまたいで揃えるため、Day 1 の値を Variables の DB_ENGINE_VERSION に固定する"
  value       = local.engine_version
}

output "instance_class" {
  value = var.instance_class
}

output "writer_endpoints" {
  value = { for k, c in aws_rds_cluster.shard : k => c.endpoint }
}

output "cluster_identifiers" {
  value = { for k, c in aws_rds_cluster.shard : k => c.cluster_identifier }
}

output "ecs_cluster" {
  value = aws_ecs_cluster.loadgen.name
}

output "task_definition" {
  value = aws_ecs_task_definition.loadgen.family
}
