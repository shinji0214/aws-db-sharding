# aws-db-sharding

AWS 上で Aurora MySQL の書き込みスケーリング（スケールアップとシャーディング）を検証するための環境。
Terraform + GitHub Actions（OIDC 認証・承認付き apply / destroy）で構築・削除する。

- 準備手順: [docs/setup.md](docs/setup.md)
- スタック: `terraform/github-oidc`（アカウント共通）、`terraform/bootstrap`（手元PC）、`terraform/base` / `terraform/db`（Actions）
