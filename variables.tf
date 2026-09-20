variable "region" {
  description = "Managed Knowledge Base をデプロイするリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "name_prefix" {
  type    = string
  default = "mkb-syncsched"
}

# syncSchedule は provider 未対応なので、ここで指定した値を AWS CLI 経由で流し込む
variable "sync_schedule" {
  description = "CreateDataSource/UpdateDataSource の syncSchedule (daily / weekly / monthly のいずれか1つ)"
  type        = any
  default = {
    weekly = {
      dayOfWeek = "MONDAY"
    }
  }
}
