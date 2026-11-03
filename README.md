# aws-db-sharding

AWS 上で Aurora MySQL の書き込みスケーリング（スケールアップとシャーディング）を検証するための環境。
Terraform + GitHub Actions（OIDC 認証・承認付き apply / destroy）で構築・削除する。

- 準備手順: [docs/setup.md](docs/setup.md)
- 検証の実施手順: [docs/experiment.md](docs/experiment.md)
- スタック: `terraform/github-oidc`（アカウント共通）、`terraform/bootstrap`（手元PC）、`terraform/base` / `terraform/db`（Actions）
- 負荷生成: ECS Fargate で sysbench を動かす（`loadgen/`、起動は `scripts/loadgen.ps1`）
