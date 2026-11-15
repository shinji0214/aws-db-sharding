# 検証の実施手順（Aurora + ECS Fargate）

計画書（Claude Doc「Aurora Write水平スケール(シャーディング)検証計画 v2」）のシナリオを、このリポジトリのコードで実行する手順。
AWS の準備（bootstrap・Secrets・Environment）は [setup.md](setup.md) を先に済ませる。コマンドは Windows PowerShell。

> **構築（apply）は yamada の合図があってから行う。** ここに書いた手順は合図の後に使う。

## 全体像

```
手元PC ──(Actions: 承認付き apply / destroy)──▶ terraform/base, terraform/db
   │
   └─(scripts/loadgen.ps1: aws ecs run-task)──▶ Fargate タスク（sysbench）──3306──▶ Aurora Writer（シャードごと）
                                                    │
                                                    └─ 結果 ─▶ S3 <PROJECT>-results-<ACCOUNT_ID>/runs/
```

| 置き場所 | 中身 | いつ作る / 消す |
|---|---|---|
| `terraform/base` | VPC、サブネット（public 1つ、シャードごとの DB 用 a/b/c、AZ-c の予備1つ）、SG、シャードごとの NACL、ECR、結果バケット、ログ | 最初に1回 apply。検証が全部終わったら destroy |
| `terraform/db` | Aurora クラスタ（シャードごとに Writer 1台）、パラメータグループ、ECS クラスタとタスク定義、IAM ロール | 作業日の始めに apply、終わりに destroy |
| `loadgen/` | 負荷ツールのイメージ（sysbench + Lua、`lab` コマンド） | Actions「負荷ツールのイメージ作成」で ECR に push |
| `scripts/loadgen.ps1` | タスクを1つ起動するスクリプト | 測定のたびに実行 |

### 旧計画（負荷EC2）からの変更点

| 項目 | 負荷EC2（旧） | Fargate（今回） |
|---|---|---|
| 負荷側の大きさ | c7g.large（2 vCPU / 4 GB） | タスク 2 vCPU / 4 GB（ARM64）。`loadgen_cpu` / `loadgen_memory` で変更 |
| 接続方法 | SSM Session Manager | `scripts/loadgen.ps1` でタスクを起動。手で触るときは ECS Exec |
| 負荷側 CPU の記録 | mpstat / sar | タスク内の mpstat（各段階の平均を summary.csv に記録）+ Container Insights |
| 70% ルール | 負荷EC2の CPU | タスクの CPU。超えた段階は summary.csv の `valid` が `no` になる。続くならタスクを大きくするか、同時に2つ起動する |
| 結果の回収 | EC2 から手で回収 | タスクが段階ごとに S3 へ上げる。`loadgen.ps1 -Sync` で手元へ |
| F3 ネットワーク断 | 負荷EC2で iptables | Fargate では iptables が使えない（NET_ADMIN 不可）ため、B の DB サブネットの NACL に拒否ルールを足す |
| 帯域の上限確認（ethtool） | `ethtool -S` の allowance 系カウンタ | Fargate では見られない。SELECT 1 の最大 QPS と DB 側の NetworkThroughput で代用 |

## 作業日の流れ

測定は4回（＋再配置の測定5）に分けて行う。各回で撮るもの・確かめることを、手順の中に「📷」で書いてある。
番号（M1-6 など）は記事用のチェックリスト（プロジェクトファイルの `articles/capture-checklist.md`）と対応する。

| 回 | 構成 | この手順書の節 |
|---|---|---|
| 測定1 | 1台 | 共通: 作業日の始め → Day 1 のシナリオ1 |
| 測定2 | 1台 | 共通 → Day 1 の測り直し・まとめてコミット・シナリオ3（任意で t4g.large） |
| 測定3 | 2台 | 共通 → Day 2 のシナリオ2・3 |
| 測定4 | 2台 | 共通 → Day 2 のシナリオ4・XA・F3・F4 |

📷 撮るときの注意（毎回）: アカウント ID（コンソール右上、ARN、バケット名、ECR の URI）、Aurora エンドポイントのランダム部分、
メールアドレスは写さないか塗りつぶす。CloudWatch は UTC 表示にし、summary.csv の `start_utc` / `end_utc` に範囲をそろえる。
ファイル名は `<回>-<番号>-<内容>.png`（例: `m1-08-cw-cpu-commitlatency.png`）。数値はスクショだけにせず、CSV・JSON・テキストでも残す。

### Day 0（AWS 費用なし）: 手元で負荷スクリプトを確認

Docker Desktop があれば、MySQL 8.0 を2台立てて `lab` コマンドの動きを確かめられる（数値は性能の目安にならない）。

```powershell
cd loadgen
docker compose up -d mysql-a mysql-b
docker compose run --rm loadgen prepare --rows 10000
docker compose run --rm loadgen sweep --scenario s2 --threads "2 4" --time 10 --warmup 3 --rows 10000
docker compose run --rm loadgen sums
docker compose down -v
```

結果は `loadgen/results/<run_id>/summary.csv` に出る。

### 共通: 作業日の始め

1. Actions → **構築・削除（Terraform）** → stack `db` / action `apply`、shards と instance_class を選ぶ → 承認
   - パターン1: `["a"]`、パターン2: `["a","b"]`
   - 所要 15〜20 分程度（Aurora の作成待ち）
   - 📷 測定1: apply ジョブの所要時間（M1-1）、承認待ちの画面（P2-3 を撮り直す場合）
   - 📷 測定1・3: RDS コンソールのクラスタ一覧（M1-2 / M3-1。エンドポイントを塗りつぶす）
2. 初回だけ: ジョブサマリーの outputs に出た `engine_version` を Variables に固定する（作業日をまたいで揃えるため）

   ```powershell
   gh variable set DB_ENGINE_VERSION --body "<engine_version の値>"
   ```

   - 📷 測定1: `engine_version` を固定したか確認（M1-3）

3. データを入れる（シャード構成を変えたら毎回やり直す）

   ```powershell
   $env:AWS_PROFILE = "<PROFILE>"; aws sso login --profile <PROFILE>
   .\scripts\loadgen.ps1 'prepare --rows 100000' -Follow
   ```

   `-Follow` はタスクのログを流し、タスクが止まると「タスクが終了しました」と出して自動で抜ける。

   - 📷 prepare の最後と `lab sums` の出力（測定1: M1-4、測定3: A に奇数・B に偶数で半分ずつ M3-2）

4. 負荷側の上限を測っておく（DB ではなくタスクの限界を知るため）

   ```powershell
   .\scripts\loadgen.ps1 'sweep --scenario select1 --select1 --threads "16 64 256" --time 60 --warmup 10' -Follow
   ```

   - 📷 測定1: select1 の summary.csv（負荷側の最大 QPS。M1-5）

### Day 1: パターン1（シナリオ1・3）

題材はゲーム。プレイヤーは player_id でシャードに振り分ける（2シャードなら A = 奇数、B = 偶数）。
シナリオ1・2はランダムなプレイヤーへの経験値加算、シナリオ3は全員でワールドボスの HP を削る。

測定1:

```powershell
# シナリオ1: 単一 Writer の限界（9段階。各段階 1分ウォームアップ + 3分計測 = 約36分）
# t4g.medium は max_connections が 90 前後なので、段階は 80 までにする。
# 上限を超える段階は lab が自動でスキップし（summary.csv の valid=skip(...)）、実際の値は meta.txt の max_connections に残る
.\scripts\loadgen.ps1 'sweep --scenario s1 --label pattern1-t4g.medium --threads "1 2 4 8 16 32 48 64 80"' -Follow
```

測定2（別の日。db を apply して prepare からやり直す）:

```powershell
# 飽和点付近を3回ずつ測り直す（例: 32〜80 が飽和点付近だった場合。t4g.medium は 80 まで）
.\scripts\loadgen.ps1 'sweep --scenario s1 --label pattern1-repeat --threads "32 64 80" --repeat 3' -Follow

# H2 の確認（任意）: 10件まとめてコミット
.\scripts\loadgen.ps1 'sweep --scenario s1-batch10 --batch 10 --threads "8 32 80"' -Follow

# シナリオ3: ホットスポット（全員でワールドボス 1 を殴る）
.\scripts\loadgen.ps1 'sweep --scenario s3 --boss 1 --threads "1 2 4 8 16 32 64"' -Follow
```

📷 測定1（シナリオ1の後、destroy の前に）
- シナリオ1の summary.csv をそのまま保存（M1-6）。`valid = no` の段階がないか確認し、あれば記録（M1-12）
- 飽和点の段階の `stepNN-...-a.txt`（sysbench の1秒ごとの出力）の一部（M1-7）
- CloudWatch: CPUUtilization と CommitLatency を同じグラフで（M1-8）、CPUCreditBalance / CPUSurplusCreditBalance /
  CPUSurplusCreditsCharged（M1-9）、DMLThroughput / CommitThroughput / DatabaseConnections（M1-10）。すべて get-metric-data の JSON も残す
- Database Insights: 飽和点の前後の待機イベント上位（M1-11）
- `lab sql a` で `SHOW VARIABLES LIKE 'max_connections'` の実値（M1-13）

📷 測定2
- 飽和点付近を3回ずつ測った summary.csv（ばらつきが 10% 以内か。M2-1）
- s1-batch10 の summary.csv と、そのときの CommitLatency（M2-2）
- シナリオ3の summary.csv と `lab sums` のボス HP（M2-3）、シナリオ3中の CPU と CommitLatency（M2-4）
- Database Insights: シナリオ3の待機イベント（行ロック待ちが上位に来るか。M2-5）
- シナリオ3の最中に ECS Exec で `SELECT * FROM performance_schema.data_lock_waits LIMIT 10`（M2-6）。
  sweep は端末を占有するので、別のターミナルで事前に `loadgen.ps1 -Exec` で待機タスクを起動して入っておく
- 1 ÷ CommitLatency とボスへの最大 TPS が近いかを計算して記録（M2-7）

任意: 「大きい1台で足りないか」を見るなら、Actions で同じ `db` を instance_class `db.t4g.large` に変えて apply し、
シナリオ1をもう一度流す（label を `pattern1b-t4g.large` に）。データは残るので prepare は不要。変更にかかった時間も記録する。

- 📷 測定2（任意 1b）: instance_class の変更にかかった時間と、t4g.large でのシナリオ1の summary.csv（M2-8）

作業の終わりに **db を destroy**（下の「作業日の終わり」）。

### Day 2: パターン2（シナリオ2・3・4・XA）

1. Actions で `db` を shards `["a","b"]`、instance_class `db.t4g.medium` で apply
2. prepare をやり直す（A に奇数 ID、B に偶数 ID のプレイヤーとそのアイテム）
3. 測定

```powershell
# シナリオ2: 総スレッド数を同じ段階で増やし、A と B に半分ずつ割り当てる（総 TPS = 2シャードの合計）
.\scripts\loadgen.ps1 'sweep --scenario s2 --label pattern2' -Follow

# 固定レート: パターン1の最大 TPS の 80% を全体のレートにして P99 を比べる（例: 最大 TPS が 3000 なら 2400）
.\scripts\loadgen.ps1 'sweep --scenario s2-fixed --rate 2400 --threads "64"' -Follow

# シナリオ3: ホットスポット（ワールドボス 1 は A にいるので、シャードを増やしても全スレッドが A に向かう）
.\scripts\loadgen.ps1 'sweep --scenario s3 --boss 1 --threads "1 2 4 8 16 32 64"' -Follow
```

📷 測定3
- シナリオ2の summary.csv（M3-3）と、固定レートの summary.csv（P95 / P99 を1台と比べる。M3-4）
- CloudWatch: A と B の CPUUtilization を同じグラフで（偏りがないか。M3-5）
- シナリオ3（2台）の summary.csv と、A と B の CPU（B が暇なまま。M3-6）
- Database Insights: シナリオ2の A と B の待機イベント（M3-7）

#### シナリオ4・XA: アイテムトレード（`lab trade`）

トレード = 「売り手のアイテムを買い手に渡し、買い手は売り手にゴールドを払う」。PHP のワーカー（`loadgen/php/trade.php`）を
`--workers` 本並べて流す。2人が同じシャードなら1トランザクション、別のシャードなら2つの DB を更新する。
実行の前後に `lab check` が走り、ゴールド合計・アイテムの増殖と消失・途中で止まったトレード・XA の残りを照合する。

```powershell
# まず障害なしで流す（素朴版でも、落ちなければ整合性は保たれる）。性能は同一シャード / 別シャードの P95 を比べる
.\scripts\loadgen.ps1 'trade --mode naive --workers 8 --time 120' -Follow

# F1: 売り手側の COMMIT 直後にワーカー1を強制終了 → アイテム消失・ゴールドが増える
.\scripts\loadgen.ps1 'trade --mode naive --fault crash-between --fault-at 50' -Follow
# 順番を逆にすると（買い手側を先に COMMIT）→ アイテム増殖
.\scripts\loadgen.ps1 'trade --mode naive --order buyer-first --fault crash-between --fault-at 50' -Follow

# F2: 存在しない買い手とのトレード → 補償処理が無いと売り手側だけ確定して消失。--compensate で元に戻す
.\scripts\loadgen.ps1 'trade --mode naive --fault missing-buyer --fault-at 50' -Follow
.\scripts\loadgen.ps1 'trade --mode naive --fault missing-buyer --fault-at 50 --compensate' -Follow

# XA（2相コミット）: 同じ障害を入れても整合性が保たれる。別シャードの P95 が素朴版よりどれだけ遅いかも見る
.\scripts\loadgen.ps1 'trade --mode xa --fault missing-buyer --fault-at 50' -Follow
# XA の弱点: PREPARE 直後に落ちる → 両シャードに準備済みトランザクションが残り、その行に触るトレードがロック待ちになる
.\scripts\loadgen.ps1 'trade --mode xa --fault crash-after-prepare --fault-at 50' -Follow
```

summary.json の主な項目: `cross_ok`（別シャードで成功）、`half_done`（片側だけ確定、または結果が分からない）、
`dup_key`（同じアイテムが既にあって INSERT できなかった = 増殖の後に出る）、`lock_timeout`（XA で固まった行に当たった）、
`xa_in_doubt`（XA の COMMIT が途中で失敗し、準備済みが残った）。どちらの順番でも最初に売り手のアイテムをロックするので、
障害を入れなければ素朴版でも整合性は保たれる。

障害を入れた試行の後は、次の試行の前に `prepare` で世界を作り直す（崩れたままだと結果が混ざる）。
XA の後始末は ECS Exec で入って行う（`lab xa-recover` で表示、`--commit` / `--rollback` で片付け）。
片付けた後に `lab check` で整合性が戻ったことを確かめる。

> Aurora のマスターユーザーで `XA RECOVER` が全セッション分見えるか（XA_RECOVER_ADMIN 権限）は要確認。
> 見えない場合は `GRANT XA_RECOVER_ADMIN ON *.* TO admin` を試す。

F3・F4 は `lab trade --time 300` を流している間に、手元から次の AWS 操作を行う。ネットワーク断や再起動の間に
別シャードのトレードが失敗し、`half_done`（片側だけ確定、または結果が分からない）が増えるかを見る。

📷 測定4（トレード・XA）
- 障害なし（naive）の summary.json と `lab check`（整合性 yes。M4-1）
- seller-first + crash-between の `lab check`（消失・ゴールド増）と、ワーカーの「障害注入: … 強制終了」のログ（M4-2）
- buyer-first + crash-between の `lab check`（増殖・ゴールド減。M4-3）
- missing-buyer の `lab check`。補償なし（消失）と `--compensate`（yes）の2つ（M4-4）
- xa + missing-buyer の summary.json と `lab check`（yes。M4-5）
- xa + crash-after-prepare: `lab xa-recover --commit` の前に、`lab sql a` / `lab sql b` で `XA RECOVER`（同じ trade_id が1件ずつ。M4-6）、
  そのときの summary.json の `lock_timeout` と `lab check` の「XA 準備済み 2 件」（M4-7）
- `lab xa-recover` → `--commit` → `lab check` で yes に戻るところ（M4-8）
- 各 summary.json の `same_p95_ms` / `cross_p95_ms` を naive と xa で控える（M4-9）
- Database Insights: XA の試行中の待機イベント（M4-13）

#### F3: B へのネットワーク断（NACL）

NACL はステートレスなので、確立済みの接続も即座に止まる（SG のルール削除は既存の接続を切らないことがある）。

```powershell
$nacl = aws ec2 describe-network-acls --filters "Name=tag:Name,Values=db-sharding-aws-db-b" --query "NetworkAcls[0].NetworkAclId" --output text
# 断: 負荷タスクのサブネット（10.40.0.0/24）からの通信を拒否（ルール番号 50 は全許可の 100 より先に評価される）
aws ec2 create-network-acl-entry --network-acl-id $nacl --ingress --rule-number 50 --protocol -1 --rule-action deny --cidr-block 10.40.0.0/24
# 復旧
aws ec2 delete-network-acl-entry --network-acl-id $nacl --ingress --rule-number 50
```

- 📷 測定4: 拒否ルール（50番）を足した NACL の画面（復旧の delete の前に撮る）と、その間の summary.json の `half_done` / `xa_in_doubt`（M4-10）

Terraform は全許可のルール（100番）だけを管理しているので、手で足した 50 番は plan の差分にならない。
**destroy の前に必ず消す**（残っていても destroy は通るが、次回の測定が全部失敗する）。

#### F4: B の DB 再起動

```powershell
aws rds reboot-db-instance --db-instance-identifier db-sharding-aws-b-1
```

- 📷 測定4: RDS のイベント画面（B の再起動）と、その間の summary.json（M4-11）

### 中に入って手で操作する（ECS Exec）

Session Manager plugin を入れておく（[インストール手順](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)）。

```powershell
.\scripts\loadgen.ps1 -Exec      # 待機タスクを起動し、入るためのコマンドを表示する
# 表示された aws ecs execute-command ... を実行して中へ
lab sql a                        # シャード a に mysql でつなぐ（パスワードは環境変数から自動）
lab sums                         # 全シャードのプレイヤー数・経験値・ゴールド・アイテム数・ボス HP
lab check                        # 整合性チェック（ゴールド合計・アイテムの増殖/消失・XA の残り）
```

待機タスクは 1 時間で自動的に終わる（止め忘れ防止）。早く止めるときは表示された `aws ecs stop-task` を使う。

## 記録されるもの

`s3://<PROJECT>-results-<ACCOUNT_ID>/runs/<run_id>/`（run_id = `開始時刻-シナリオ-シャード数-インスタンス種別`）

| ファイル | 中身 |
|---|---|
| `summary.csv` | 段階ごとの TPS、P95 / P99（ミリ秒、全シャードのヒストグラムを合算）、無視したエラー数（デッドロック・ロック待ちタイムアウト）、負荷側 CPU、有効 / 無効、開始・終了時刻（UTC） |
| `meta.txt` | 実行条件（スレッド段階、行数、インスタンス種別、エンジンバージョン、イメージのダイジェスト、タスクの AZ） |
| `stepNN-tTTT-rR-<shard>.txt` | sysbench の出力そのまま（1秒ごとの推移とヒストグラム） |
| `stepNN-tTTT-rR-mpstat.txt` | 負荷タスクの CPU（1秒ごと） |

DB 側のメトリクスは summary.csv の開始・終了時刻で取り出す（画面のスクリーンショットだけにしない）。

```powershell
# 例: CloudWatch（1分粒度）。時刻は summary.csv の start_utc / end_utc
# scripts/cw-metrics-a.json はシャード a の Writer 用。b はファイル内の db-sharding-aws-a-1 を -b-1 に変えたコピーを使う
aws cloudwatch get-metric-data --start-time 2026-11-10T01:00:00Z --end-time 2026-11-10T01:40:00Z `
  --metric-data-queries file://scripts/cw-metrics-a.json --output json > results/cw-<run_id>-a.json
```

Database Insights は Standard モード（無料、7日保持）で有効にしてある。db を destroy するとそのインスタンスの
データも見られなくなるので、待機イベントの上位などは **destroy の前に** `aws pi get-resource-metrics` で取り出す。

db.t4g.medium では Database Insights による Performance Schema の自動管理が効かないため、パラメータグループで
手動で有効にしている（シナリオ3の `performance_schema.data_lock_waits` に必要）。

## 作業日の終わり

1. 結果を手元へ: `.\scripts\loadgen.ps1 -Sync`
2. Database Insights / CloudWatch のメトリクスを取り出す（上の節）
3. F3 の NACL ルールを消したか確認
   - 📷 測定4: 確認した結果を記録（M4-12）
4. Actions → stack `db` / action `destroy` → 承認
   - 📷 測定1: destroy の承認とジョブ完了（M1-14）
5. 残存確認（タグの Project は `db-sharding-aws`）

   ```powershell
   aws rds describe-db-clusters --query "DBClusters[].DBClusterIdentifier"
   aws rds describe-db-cluster-snapshots --snapshot-type manual --query "DBClusterSnapshots[].DBClusterSnapshotIdentifier"
   aws ecs list-tasks --cluster db-sharding-aws-loadgen   # 削除済みクラスタは INACTIVE で残るので、"taskArns": [] なら正常
   aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=db-sharding-aws --query "ResourceTagMappingList[].ResourceARN"
   ```

   最後のコマンドには base のもの（VPC・サブネット・SG・NACL・ECR・S3・ロググループ）が残るのが正常。
   タグ API は削除直後のリソースをしばらく返すことがあるので、個別の describe を正とする。

   - 📷 測定1: 残存確認コマンドの出力（M1-14。ARN は塗りつぶす）

6. 翌日、Cost Explorer で前日の課金が想定内か確認する

   - 📷 全部終わった後: Cost Explorer で `Project = db-sharding-aws` の日別費用（C-1）とサービス別の内訳（C-2）

## 費用の目安（東京、要確認）

| 項目 | 単価の目安 | 備考 |
|---|---|---|
| Aurora db.t4g.medium（I/O-Optimized） | 約 $0.1/h + 高負荷中の CPU 超過課金 | シャード数ぶん。作業日ごとに destroy |
| Fargate タスク 2 vCPU / 4 GB（ARM64） | 約 $0.1/h | 動いている秒数だけ。シナリオ1の1回（約36分）で約 $0.06 |
| Container Insights | 1日あたり数円 | タスクが動いている間のメトリクス分 |
| ECR / S3 / CloudWatch Logs | 月 $1 未満 | イメージ数百 MB、結果は数十 MB |
| NAT Gateway・VPC エンドポイント | 0 | 作らない（タスクはパブリック IP で外へ出る。インバウンドは全て閉じている） |

予算アラート（月 $30）は bootstrap で作る（[setup.md](setup.md) の 2）。
