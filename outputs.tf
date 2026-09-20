output "knowledge_base_id" {
  value = aws_bedrockagent_knowledge_base.this.id
}

output "data_source_id" {
  value = aws_bedrockagent_data_source.s3.data_source_id
}

output "bucket" {
  value = aws_s3_bucket.docs.id
}

output "verify_command" {
  description = "設定された syncSchedule を確認するコマンド"
  value = join(" ", [
    "aws bedrock-agent get-data-source",
    "--region ${var.region}",
    "--knowledge-base-id ${aws_bedrockagent_knowledge_base.this.id}",
    "--data-source-id ${aws_bedrockagent_data_source.s3.data_source_id}",
    "--query 'dataSource.dataSourceConfiguration.managedKnowledgeBaseConnectorConfiguration.syncSchedule'",
  ])
}

output "region" {
  value = var.region
}
