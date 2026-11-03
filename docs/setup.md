# AWS 環境の準備手順（Terraform + GitHub Actions / OIDC）

手元PCで bootstrap を1回だけ apply し、以後の構築・変更・削除は GitHub Actions の Run workflow（承認付き）で行う。
AWS の認証はアクセスキーを使わず OIDC。コマンドは Windows PowerShell。

## 構成

| スタック | 中身 | どこから apply | state | 消す時期 |
|---|---|---|---|---|
| `terraform/github-oidc` | GitHub Actions の OIDC プロバイダ（アカウント共通） | 手元PC | 手元 | 消さない |
| `terraform/bootstrap` | state バケット、plan / apply ロール | 手元PC | 手元 | 検証が全部終わったら |
| `terraform/base` | VPC など、作業日をまたいで残すもの | Actions | S3 | 検証が全部終わったら |
| `terraform/db` | Aurora、負荷生成の ECS（Fargate）など課金の大きいもの | Actions | S3 | 作業日ごと |

| ロール | 使う場面 | 入れる条件 | 権限 |
|---|---|---|---|
| `db-sharding-aws-gha-plan` | plan・whoami | main ブランチのワークフロー | ReadOnlyAccess |
| `db-sharding-aws-gha-apply` | apply・destroy | Environment `db-sharding-aws-apply` の承認済みジョブ | rds / ec2 / ecs / ecr / 監視など必要な分だけ |

## 費用

- github-oidc / bootstrap / base（VPC のみ）: ほぼ 0 円。S3 の state は数 KB で月 1 円未満
- 課金の中心は db スタック（Aurora）。作業が終わったら必ず `db` を destroy する
- 負荷生成は ECS Fargate のタスクを測定のたびに起動する。課金はタスクが動いている間だけ（秒単位）
- NAT Gateway は時間課金が大きいので作らない方針。Fargate タスクは public サブネットにパブリック IP 付きで置き、
  インバウンドはすべて閉じる（ECR からのイメージ取得とログ送信のため。VPC エンドポイントは1つごとに時間課金がある）

📝 学習メモ: 負荷生成側が先に詰まると DB の限界を測れない。タスクの CPU 使用率（Container Insights）も一緒に記録し、
足りなければタスク数を増やす

## 0. 決めたこと

- `<PROJECT>` = `db-sharding-aws`、リージョン = `ap-northeast-1`
- AWS アカウント: ハニーポット検証と同じ管理アカウント（Identity Center のプロファイルを流用）
- このリポジトリは 2026-07-15 以降に作成したので、OIDC の `sub` は ID 付き形式
  `repo:<OWNER>@<OWNER_ID>/<REPO>@<REPO_ID>:...`。ID は次で確認できる（秘密情報ではない）

```powershell
gh api repos/<OWNER>/<REPO> --jq '{id, owner_id: .owner.id, created_at}'
```

## 1. OIDC プロバイダを専用スタックへ移す（github-oidc）

📝 学習メモ: OIDC プロバイダ（`token.actions.githubusercontent.com`）はアカウントに1つしか作れない。
今はハニーポット検証の bootstrap の state が持っているので、そちらを destroy すると、プロバイダを参照している
このリポジトリの Actions も `No OpenIDConnect provider found` で止まる。
どのプロジェクトにも属さないスタックに持ち主を移せば、各プロジェクトの bootstrap を自由に作って消せる。
AWS 上のプロバイダは作り直さず、state の持ち主だけを付け替えるので、ハニーポットの Actions も止まらない。

```powershell
$env:AWS_PROFILE = "<PROFILE>"
aws sso login --profile <PROFILE>        # 切れていれば
aws sts get-caller-identity              # AWSReservedSSO_AdministratorAccess_... なら OK

cd terraform/github-oidc
terraform init
terraform plan    # 「1 to import」と、タグの変更（Project=shared など）だけが出ることを確認
terraform apply
```

- `prevent_destroy = true` にしてあるので、誤って destroy しようとしても止まる
- プロバイダがまだ無い新しいアカウントで使うときは、`main.tf` の `import` ブロックを消してから apply する

### 1-2. ハニーポット側から手放す（ハニーポットのリポジトリで実施）

1 の apply が終わってから行う。順番が逆でも AWS 上のプロバイダは消えないが、持ち主がいない時間を作らないため。

```powershell
cd <ハニーポットのリポジトリ>/terraform/bootstrap
# terraform.tfvars に create_github_oidc_provider = false を設定（既存を参照する側に切り替える）
terraform state rm 'aws_iam_openid_connect_provider.github[0]'
terraform plan    # No changes になることを確認（ロールの信頼ポリシーが参照する ARN は同じ）
```

- `state rm` は Terraform の管理から外すだけで、AWS 上のプロバイダは消さない
- tfvars を false にせず `state rm` だけすると、次の apply でプロバイダを作り直そうとして `EntityAlreadyExists` になる

## 2. bootstrap を apply（このリポジトリ）

```powershell
cd terraform/bootstrap
copy terraform.tfvars.example terraform.tfvars   # <OWNER> などを埋める（tfvars は .gitignore 済み）
terraform init
terraform plan    # S3 バケット・ロール2つ・ポリシーが作られる。OIDC プロバイダは作られない（data で参照）
terraform apply
```

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

- Required reviewers: 自分
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
2. **構築・削除（Terraform）** → stack `base` / action `plan`。リソースがまだ無いので `No changes` になれば経路は正常
3. 同じく `apply` → 承認 → 成功すれば apply ロールも正常

## このリポジトリは public

- Actions のログ・ジョブサマリーは誰でも見られる。ワークフローはアカウントIDを伏せ字にしている
- plan ファイルは Artifact で受け渡さない（apply ジョブで改めて plan して適用）
- fork の PR には OIDC トークンが発行されない。`workflow_dispatch` は書き込み権限のある人しか実行できない

## 片付け

1. 作業日の終わり: Actions で `db` を destroy
2. 検証が全部終わったら: Actions で `base` を destroy（db → base の順）
3. 手動で作ったもの（スナップショット等）を削除
4. 手元PCで `terraform/bootstrap` を `terraform destroy`（state バケットは中身ごと消える）
5. `terraform/github-oidc` は残す（他プロジェクトの Actions も使う）
6. GitHub の Secrets / Environment は不要なら削除
