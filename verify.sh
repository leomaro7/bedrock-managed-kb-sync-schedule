#!/usr/bin/env bash
# syncSchedule が実際に保存されているかを確認する（読み取りのみ・課金なし）
set -euo pipefail
cd "$(dirname "$0")"

REGION=$(terraform output -raw region)
KB_ID=$(terraform output -raw knowledge_base_id)
DS_ID=$(terraform output -raw data_source_id)

echo "== knowledge base =="
aws bedrock-agent get-knowledge-base --region "$REGION" --knowledge-base-id "$KB_ID" \
  --query 'knowledgeBase.{status:status,type:knowledgeBaseConfiguration.type,managed:knowledgeBaseConfiguration.managedKnowledgeBaseConfiguration}' \
  --output json

echo "== data source =="
aws bedrock-agent get-data-source --region "$REGION" --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" \
  --query 'dataSource.{status:status,config:dataSourceConfiguration}' --output json

echo "== syncSchedule のみ =="
aws bedrock-agent get-data-source --region "$REGION" --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" \
  --query 'dataSource.dataSourceConfiguration.managedKnowledgeBaseConnectorConfiguration.syncSchedule' \
  --output json
