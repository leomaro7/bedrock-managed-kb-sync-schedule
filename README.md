# Bedrock Managed Knowledge Base の自動同期スケジュールを Terraform で設定する

[Amazon Bedrock マネージドナレッジベースがデータソースコネクタの自動同期スケジューリングをサポート](https://aws.amazon.com/jp/about-aws/whats-new/2026/09/amazon-bedrock-managed-knowledge-base-automatic-sync-scheduling-data-source-connectors/)（2026-09-04）の検証。

検証環境: Terraform 1.16.3 / hashicorp/aws 6.65.0 / AWS CLI 2.36.45 / ap-northeast-1
検証日: 2026-09-20（実機で作成・確認・削除まで実施）

## 結論

`syncSchedule` は **Bedrock API にしか存在せず、IaC からは直接書けない**。

| 経路 | Managed KB 本体 | `syncSchedule` |
|---|---|---|
| bedrock-agent API / AWS CLI | ✅ | ✅ `managedKnowledgeBaseConnectorConfiguration.syncSchedule` |
| hashicorp/aws 6.65.0 | ✅ v6.56.0 で追加 | ❌ `terraform providers schema -json` 全文で `sync_schedule` 0 件 |
| CloudFormation `AWS::Bedrock::DataSource` | ✅ | ❌ プロパティは `ConnectorParameters` / `DeletionProtectionConfiguration` / `MediaExtractionConfiguration` のみ |
| awscc 1.102.0 | ✅ | ❌（CFN スキーマ生成のため必然） |
| `aws_cloudcontrolapi_resource` | ✅ | ❌（同上。CFN に無いので先取りできない） |

よって **土台は Terraform、`syncSchedule` だけ UpdateDataSource API** のハイブリッドにする。

## 構成

```
versions.tf        terraform 1.16+ / aws ~> 6.65 / random
variables.tf       region, name_prefix, sync_schedule
main.tf            S3 + IAM + Managed KB + データソース
sync_schedule.tf   terraform_data + local-exec で syncSchedule を後乗せ
outputs.tf         KB ID / データソース ID / 確認コマンド
verify.sh          実機の状態を読み取るだけのスクリプト（課金なし）
```

```bash
terraform init
terraform apply
./verify.sh
terraform destroy
```

スケジュールの切り替え:

```bash
terraform apply -var='sync_schedule={weekly={dayOfWeek="MONDAY"}}'
terraform apply -var='sync_schedule={daily={}}'
terraform apply -var='sync_schedule={monthly={dayOfMonth={dayNumber=15}}}'
terraform apply -var='sync_schedule={monthly={dayOfMonth={lastDayOfMonth={}}}}'
```

## ハマりどころ（すべて実機で踏んだもの）

### 1. `aclEnabled` と `media_extraction_configuration` を省くと apply が落ちる

```
Error: Provider produced inconsistent result after apply
...connector_parameters: was cty.StringVal("{...}"), but now cty.StringVal("{...,\"aclEnabled\":false,...}")
...media_extraction_configuration: block count changed from 0 to 1.
```

AWS 側が `aclEnabled: false` と `imageExtractionStatus: ENABLED` を補って返すのに、
provider がそれを Computed 扱いしていないため。**provider ドキュメントの例どおり両方を明示する**と通る。

失敗した apply でリソースは AWS 上に作られ、Terraform 側では tainted になる。
次の apply で作り直しになるが、マネージド KB のデータソース削除は 4 分ほどかかる。

### 2. Terraform 側の更新だけで `syncSchedule` が消える

`UpdateDataSource` は `dataSourceConfiguration` を**全置換**する。
`description` を足しただけの in-place 更新でも、provider は `syncSchedule` を知らないので送らず、結果としてスケジュールが `On-demand` に戻る。

対策として `terraform_data` に `replace_triggered_by` を付ける:

```hcl
lifecycle {
  replace_triggered_by = [aws_bedrockagent_data_source.s3]
}
```

ただしこれは**同じ plan 内でデータソースが変わるときにしか効かない**。
コンソールなどで外から消されたスケジュールは自己修復しない（provider が差分を検知できないため `terraform plan` は "No changes" と言う）。
その場合は `terraform apply -replace=terraform_data.sync_schedule` で流し直す。

### 3. CLI 側も全置換なので、Terraform 管理下の属性を巻き込む

`update-data-source` で `--description` を省くと description が消える。すると次の plan で Terraform が戻そうとし、その更新で `syncSchedule` がまた消え、`replace_triggered_by` で CLI が走り description がまた消える——と、**収束しない apply ループ**になる。

local-exec 側でも `--description` と `--data-deletion-policy` を Terraform の値から渡して解消した。

### 4. heredoc 内の bash 配列展開

`"${desc_arg[@]}"` は Terraform の補間と衝突する。`"$${desc_arg[@]}"` とエスケープする。

## syncSchedule のスキーマ

tagged union。`daily` / `weekly` / `monthly` のいずれか1つだけ。

- `daily` — 空オブジェクト。実行時刻は AWS が選ぶオフピーク時間で指定不可
- `weekly` — `dayOfWeek` 必須（`SUNDAY`〜`SATURDAY`）
- `monthly` — `dayOfMonth` 必須。`dayNumber`（1〜28）か `lastDayOfMonth`（空オブジェクト）
- 省略すると On-demand（手動同期のみ）
- Custom コネクタは非対応

## 費用

Managed KB は生データの保存量と Retrieve API 呼び出しが課金対象で、マネージド埋め込みモデル利用時は ingestion に追加課金なし。
今回は数百バイトのテキスト1本を1時間程度置き、Retrieve は呼ばずに削除した。

## 参考

- [Sync a data source / Set a sync schedule for a data source](https://docs.aws.amazon.com/bedrock/latest/userguide/kb-managed-sync.html#kb-managed-sync-schedule)
- [Connect a data source](https://docs.aws.amazon.com/bedrock/latest/userguide/kb-managed-connect-ds.html)
- [Create a service role for managed Amazon Bedrock Knowledge Bases](https://docs.aws.amazon.com/bedrock/latest/userguide/kb-managed-permissions.html)
- [aws_bedrockagent_data_source](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagent_data_source)
- [Build enterprise search for agents with Amazon Bedrock Managed Knowledge Base](https://aws.amazon.com/blogs/machine-learning/build-enterprise-search-for-agents-with-amazon-bedrock-managed-knowledge-base/)（対応リージョンと料金モデル）
