############################################
# syncSchedule のハイブリッド適用
#
# hashicorp/aws v6.65.0 時点で aws_bedrockagent_data_source には
# sync_schedule 相当の引数が存在しない（CloudFormation / awscc も未対応）。
# そのため UpdateDataSource API を AWS CLI 経由で叩いて後乗せする。
############################################
locals {
  # UpdateDataSource は dataSourceConfiguration を全置換するので、
  # Terraform 側で書いた connector_parameters も一緒に送り直す必要がある
  data_source_configuration_with_schedule = {
    type = "MANAGED_KNOWLEDGE_BASE_CONNECTOR"
    managedKnowledgeBaseConnectorConfiguration = {
      connectorParameters = local.connector_parameters
      syncSchedule        = var.sync_schedule
    }
  }
}

resource "terraform_data" "sync_schedule" {
  # スケジュールやコネクタ設定が変わったら必ず再適用する
  triggers_replace = {
    data_source_id = aws_bedrockagent_data_source.s3.data_source_id
    configuration  = jsonencode(local.data_source_configuration_with_schedule)
  }

  # UpdateDataSource は dataSourceConfiguration を全置換するので、
  # Terraform 側がデータソースを更新しただけでも syncSchedule が消える。
  # データソースに何か変更が入ったら必ず流し直す。
  lifecycle {
    replace_triggered_by = [aws_bedrockagent_data_source.s3]
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      AWS_REGION = var.region
      KB_ID      = aws_bedrockagent_knowledge_base.this.id
      DS_ID      = aws_bedrockagent_data_source.s3.data_source_id
      DS_NAME    = aws_bedrockagent_data_source.s3.name
      DS_DESC    = coalesce(aws_bedrockagent_data_source.s3.description, "")
      DS_POLICY  = aws_bedrockagent_data_source.s3.data_deletion_policy
      DS_CONFIG  = jsonencode(local.data_source_configuration_with_schedule)
    }
    command = <<-EOT
      set -euo pipefail
      # UpdateDataSource は全置換。--description を省くと Terraform 管理下の
      # description が消え、次の plan で永久に差分が出続ける
      desc_arg=()
      if [[ -n "$DS_DESC" ]]; then
        desc_arg=(--description "$DS_DESC")
      fi

      aws bedrock-agent update-data-source \
        --region "$AWS_REGION" \
        --knowledge-base-id "$KB_ID" \
        --data-source-id "$DS_ID" \
        --name "$DS_NAME" \
        "$${desc_arg[@]}" \
        --data-deletion-policy "$DS_POLICY" \
        --data-source-configuration "$DS_CONFIG" \
        --query 'dataSource.dataSourceConfiguration.managedKnowledgeBaseConnectorConfiguration.syncSchedule' \
        --output json
    EOT
  }
}
