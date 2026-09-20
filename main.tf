data "aws_caller_identity" "current" {}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  bucket_name = "${var.name_prefix}-${data.aws_caller_identity.current.account_id}-${random_string.suffix.result}"

  # Terraform 側の connector_parameters と、CLI 側の update-data-source で同じ値を使い回す
  # aclEnabled を省くと AWS 側が false を補って返し、
  # "Provider produced inconsistent result after apply" になるので明示する
  connector_parameters = {
    type    = "S3"
    version = "1"
    connectionConfiguration = {
      bucketName           = local.bucket_name
      bucketOwnerAccountId = data.aws_caller_identity.current.account_id
    }
    aclEnabled = false
    filterConfiguration = {
      maxFileSizeInMegaBytes = "5"
    }
  }
}

############################################
# データソース用 S3（中身は検証用のテキスト1本だけ）
############################################
resource "aws_s3_bucket" "docs" {
  bucket        = local.bucket_name
  force_destroy = true
}

resource "aws_s3_object" "doc" {
  bucket  = aws_s3_bucket.docs.id
  key     = "docs/sync-schedule-note.txt"
  content = <<-EOT
    Amazon Bedrock Managed Knowledge Base の自動同期スケジュールに関する検証用メモ。
    syncSchedule には daily / weekly / monthly のいずれか1つだけを指定する。
    weekly は dayOfWeek、monthly は dayOfMonth (dayNumber 1-28 もしくは lastDayOfMonth) が必須。
    実行時刻は AWS 側が選ぶオフピーク時間で、ユーザーは指定できない。
  EOT
}

############################################
# Managed Knowledge Base 用サービスロール
############################################
data "aws_iam_policy_document" "kb_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:knowledge-base/*"]
    }
  }
}

resource "aws_iam_role" "kb" {
  name               = "${var.name_prefix}-kb-role-${random_string.suffix.result}"
  assume_role_policy = data.aws_iam_policy_document.kb_assume.json
}

data "aws_iam_policy_document" "kb" {
  statement {
    sid       = "S3ListBucketStatement"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.docs.arn]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
  statement {
    sid       = "S3GetObjectStatement"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.docs.arn}/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
  # embedding_model_type = MANAGED の場合は Bedrock 側のマネージドモデルが使われるが、
  # モデル一覧の参照権限は付けておく
  statement {
    sid       = "BedrockListModels"
    effect    = "Allow"
    actions   = ["bedrock:ListFoundationModels", "bedrock:ListCustomModels"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "kb" {
  name   = "${var.name_prefix}-kb-policy"
  role   = aws_iam_role.kb.id
  policy = data.aws_iam_policy_document.kb.json
}

############################################
# Managed Knowledge Base（ベクトルストアは Bedrock 任せ）
############################################
resource "aws_bedrockagent_knowledge_base" "this" {
  name     = "${var.name_prefix}-${random_string.suffix.result}"
  role_arn = aws_iam_role.kb.arn

  knowledge_base_configuration {
    type = "MANAGED"

    managed_knowledge_base_configuration {
      embedding_model_type = "MANAGED"
    }
  }

  depends_on = [aws_iam_role_policy.kb]
}

############################################
# S3 コネクタのデータソース
# ※ sync_schedule 引数は provider v6.65.0 に存在しないため、ここでは書けない
############################################
resource "aws_bedrockagent_data_source" "s3" {
  knowledge_base_id    = aws_bedrockagent_knowledge_base.this.id
  name                 = "s3-connector"
  data_deletion_policy = "DELETE"

  data_source_configuration {
    type = "MANAGED_KNOWLEDGE_BASE_CONNECTOR"

    managed_knowledge_base_connector_configuration {
      connector_parameters = jsonencode(local.connector_parameters)

      # 省略すると AWS 側が imageExtractionStatus=ENABLED を補って返すため明示する
      media_extraction_configuration {
        image_extraction_configuration {
          image_extraction_status = "ENABLED"
        }
      }
    }
  }
}
