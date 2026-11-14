# AWS 環境の準備手順（Terraform + GitHub Actions / OIDC）

手元PCで bootstrap を1回だけ apply し、以後の構築・変更・削除は GitHub Actions の Run workflow（承認付き）で行う。
AWS の認証はアクセスキーを使わず OIDC。コマンドは Windows PowerShell。

## 構成

| スタック | 中身 | どこから apply | state | 消す時期 |
|---|---|---|---|---|
| `terraform/github-oidc` | GitHub Actions の OIDC プロバイダ（アカウント共通） | 手元PC | 手元 | 消さない |
| `terraform/bootstrap` | state バケット、plan / apply ロール | 手元PC | 手元 | 検証が全部終わったら |
| `terraform/base` | VPC・SG・NACL、負荷ツールの ECR、結果の S3、ログなど作業日をまたいで残すもの | Actions | S3 | 検証が全部終わったら |
| `terraform/db` | Aurora、負荷生成の ECS（Fargate）など課金の大きいもの | Actions | S3 | 作業日ごと |

検証そのものの手順（作業日の流れ、負荷の掛け方、結果の回収）は [experiment.md](experiment.md)。

| ロール | 使う場面 | 入れる条件 | 権限 |
|---|---|---|---|
| `db-sharding-aws-gha-plan` | plan・whoami | main ブランチのワークフロー | ReadOnlyAccess |
| `db-sharding-aws-gha-apply` | apply・destroy | Environment `db-sharding-aws-apply` の承認済みジョブ | rds / ec2 / ecs / ecr / 監視など必要な分だけ |

## 費用

- github-oidc / bootstrap / base: ほぼ 0 円（時間課金のリソースを置かない）。ECR のイメージと結果の S3 で月 $1 未満
- 課金の中心は db スタック（Aurora）。作業が終わったら必ず `db` を destroy する
- 負荷生成は ECS Fargate のタスクを測定のたびに起動する。課金はタスクが動いている間だけ（秒単位）
- NAT Gateway は時間課金が大きいので作らない方針。Fargate タスクは public サブネットにパブリック IP 付きで置き、
  インバウンドはすべて閉じる（ECR からのイメージ取得とログ送信のため。VPC エンドポイントは1つごとに時間課金がある）

📝 学習メモ: 負荷生成側が先に詰まると DB の限界を測れない。タスクの CPU 使用率（Container Insights）も一緒に記録し、
足りなければタスク数を増やす

## 0. 決めたこと

- `<PROJECT>` = `db-sharding-aws`、リージョン = `ap-northeast-1`
- AWS アカウント: ハニーポット検証で使った管理アカウント（Identity Center のプロファイルを流用。ハニーポットは撤収済み）
- このリポジトリは 2026-07-15 以降に作成したので、OIDC の `sub` は ID 付き形式
  `repo:<OWNER>@<OWNER_ID>/<REPO>@<REPO_ID>:...`。ID は次で確認できる（秘密情報ではない）

```powershell
gh api repos/<OWNER>/<REPO> --jq '{id, owner_id: .owner.id, created_at}'
```

## 1. OIDC プロバイダを作る（github-oidc）

📝 学習メモ: OIDC プロバイダ（`token.actions.githubusercontent.com`）はアカウントに1つしか作れない。
どこかのプロジェクトの bootstrap に持たせると、その bootstrap を destroy したときに、プロバイダを参照している
他のプロジェクトの Actions も `No OpenIDConnect provider found` で止まる。
どのプロジェクトにも属さないこのスタックに持たせれば、各プロジェクトの bootstrap を自由に作って消せる。

まず、アカウントにプロバイダが既にあるかを確かめる（ハニーポット検証の bootstrap は撤収済みで、そのとき一緒に消えている見込み）。

```powershell
$env:AWS_PROFILE = "<PROFILE>"
aws sso login --profile <PROFILE>        # 切れていれば
aws sts get-caller-identity              # AWSReservedSSO_AdministratorAccess_... なら OK
aws iam list-open-id-connect-providers   # 空（[]）なら新規作成、token.actions.githubusercontent.com があれば取り込み
```

```powershell
cd terraform/github-oidc
terraform init
# プロバイダが既にある場合だけ: 作り直さずに取り込む（<ACCOUNT_ID> は get-caller-identity の Account）
# terraform import aws_iam_openid_connect_provider.github arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com
terraform plan    # 新規なら「1 to add」、取り込んだならタグの変更（Project=shared など）だけ
terraform apply
```

- `prevent_destroy = true` にしてあるので、誤って destroy しようとしても止まる
- 既にあるのに import せず apply すると `EntityAlreadyExists` で止まる。その場合は上の import をしてからやり直す

## 2. bootstrap を apply（このリポジトリ）

```powershell
cd terraform/bootstrap
copy terraform.tfvars.example terraform.tfvars   # <OWNER> や budget_email を埋める（tfvars は .gitignore 済み）
terraform init
terraform plan    # S3 バケット・ロール2つ・ポリシー・予算が作られる。OIDC プロバイダは作られない（data で参照）
terraform apply
```

予算アラート（月 $30、50% / 100% / 予測 100% でメール）はタグ `Project=db-sharding-aws` の費用だけを数える。
同じアカウントの他プロジェクトの費用を混ぜないため。タグで絞るには、Billing → **Cost allocation tags** で
`Project` を有効化しておく（反映まで最大 24 時間。有効化より前の費用は集計されないので、構築の前日までに）。

**予算の通知先メールは確認（verify）が必要。** 2026-09-30 以降に追加した宛先は、確認するまで予算アラートが届かない
（Budgets のコンソールに出ている案内による。2026-11-14 に確認）。
apply 後に AWS から届く確認メールのリンクを開く。届いていなければ Budgets → 予算の詳細 → Email verification から再送する
（状態が Pending のままだと通知されない）。

apply ロールの権限は `variables.tf` の既定値（Aurora・VPC・ECS Fargate・ECR・監視向け）。
db スタックを作っていて `AccessDenied ... <action>` が出たら、変数に足して手元PCで再 apply する。

## 3. GitHub に登録

Secrets（アカウントIDを含むので Variables ではなく Secrets）。**パイプ（`|`）で渡さない**。
Windows PowerShell のパイプは先頭に BOM が付き、`InvalidBucketName` などで失敗する。必ず `--body` を使う。

```powershell
gh secret set TF_STATE_BUCKET    --body (terraform output -raw tf_state_bucket)
gh secret set AWS_PLAN_ROLE_ARN  --body (terraform output -raw plan_role_arn)
gh secret set AWS_APPLY_ROLE_ARN --body (terraform output -raw apply_role_arn)
gh variable set PROJECT --body "db-sharding-aws"
```

Environment（Settings → Environments → New environment → `db-sharding-aws-apply`）

- Required reviewers: 自分。チェックを入れた後に出る入力欄でユーザーを追加してから保存する
  （レビュアーが空のまま保存すると、チェックが外れた状態に戻る）
- Prevent self-review: 外す（一人で運用するので、入れると自分で承認できなくなる）
- Allow administrators to bypass configured protection rules: 外す（管理者でも承認を飛ばせないようにする）
- Deployment branches and tags: Selected branches → `main` のみ

## 4. actions.lock を作る

```powershell
gh extension install github/gh-actions-lock   # 初回だけ
gh actions-lock                               # .github/workflows/actions.lock を生成 → コミット
```

- 生成ファイルは手で編集しない。`uses:` を変えたら `gh actions-lock`、バージョンを上げたら `--relock`
- テンプレートのバージョンは作成時点のもの。Dependabot の初回 PR か `--relock` で最新にする

## 5. 動作確認

1. Actions → **接続確認（OIDC whoami）** → Run workflow（main）。`sub` と `assumed-role/db-sharding-aws-gha-plan/...` が出れば OK
2. **構築・削除（Terraform）** → stack `base` / action `plan`。VPC・サブネット・ECR・S3 などの作成予定が出れば plan ロールは正常
3. 同じく `apply` → 承認 → 成功すれば apply ロールも正常（base は時間課金のリソースを含まない）

## 6. 負荷ツールのイメージを作る

base の apply の後に1回。`loadgen/` を変えたらもう一度。

1. Actions → **負荷ツールのイメージ作成** → Run workflow（main）→ 承認
2. ARM64 のランナーでビルドし、ECR の `db-sharding-aws/loadgen` に `latest` とコミット SHA のタグで push される

ここまでで準備は完了。db スタックの apply と測定は [experiment.md](experiment.md) の手順で進める。

## このリポジトリは public

- Actions のログ・ジョブサマリーは誰でも見られる。ワークフローはアカウントIDを伏せ字にしている
- plan ファイルは Artifact で受け渡さない（apply ジョブで改めて plan して適用）
- fork の PR には OIDC トークンが発行されない。`workflow_dispatch` は書き込み権限のある人しか実行できない

## 片付け

1. 作業日の終わり: Actions で `db` を destroy
2. 検証が全部終わったら: `.\scripts\loadgen.ps1 -Sync` で結果を回収し、`terraform/base/variables.tf` の
   `results_force_destroy` を true にしてから Actions で `base` を destroy（db → base の順。false のままだと
   結果バケットが空でないため destroy が止まる。回収忘れを防ぐための既定値）
3. 手動で作ったもの（スナップショット等）を削除
4. 手元PCで `terraform/bootstrap` を `terraform destroy`（state バケットは中身ごと消える）
5. `terraform/github-oidc` は残す（他プロジェクトの Actions も使う）
6. GitHub の Secrets / Environment は不要なら削除
