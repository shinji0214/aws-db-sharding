<#
.SYNOPSIS
  負荷生成タスク（ECS Fargate）を1つ起動する。db スタックを apply した後に手元PC（Windows PowerShell）から使う。

.DESCRIPTION
  タスクはコンテナの lab コマンドを実行し、終われば止まる（課金はその間だけ）。
  計測結果はタスクから S3（<PROJECT>-results-<ACCOUNT_ID>/runs/）に直接上がる。

  前提: $env:AWS_PROFILE を設定して aws sso login 済み（管理者プロファイル）。
        ECS Exec（-Exec）を使うときは Session Manager plugin をインストールしておく。

.EXAMPLE
  # lab に渡すコマンドは1つの文字列で渡す（外側をシングルクォート、値の空白はダブルクォート）
  # データ投入（10万件を全シャードに振り分け）
  .\scripts\loadgen.ps1 'prepare --rows 100000' -Follow

  # シナリオ1: スレッド数スイープ（既定の 1〜256）
  .\scripts\loadgen.ps1 'sweep --scenario s1 --label pattern1' -Follow

  # 負荷側の上限確認（SELECT 1）
  .\scripts\loadgen.ps1 'sweep --scenario select1 --select1 --threads "16 64 256" --time 60'

  # シナリオ3: ホットスポット（全員でワールドボス 1 を殴る）
  .\scripts\loadgen.ps1 'sweep --scenario s3 --boss 1 --threads "1 2 4 8 16 32 64"'

  # シナリオ4: アイテムトレード（売り手の COMMIT 直後に落ちる障害を入れる）
  .\scripts\loadgen.ps1 'trade --mode naive --fault crash-between --fault-at 50' -Follow

  # 中に入って手で操作する（mysql クライアント: lab sql a）
  .\scripts\loadgen.ps1 -Exec

  # 結果を手元の results/ に落とす
  .\scripts\loadgen.ps1 -Sync
#>
[CmdletBinding()]
param(
  # コンテナの lab コマンドに渡す引数（例: 'sweep --scenario s1'）
  [Parameter(Position = 0)]
  [string]$Lab,
  # 計測が終わるまでログを表示し続ける
  [switch]$Follow,
  # 待機タスクを起動し、ECS Exec で入るコマンドを表示する
  [switch]$Exec,
  # S3 の結果を results/ に同期する（タスクは起動しない）
  [switch]$Sync,
  [string]$Project = "db-sharding-aws",
  [string]$Region = "ap-northeast-1"
)

$ErrorActionPreference = "Stop"
$Cluster = "$Project-loadgen"
$Family = "$Project-loadgen"
$LogGroup = "/ecs/$Project/loadgen"

function Invoke-Aws {
  $out = & aws @args --region $Region --output json
  if ($LASTEXITCODE -ne 0) { throw "aws $($args -join ' ') が失敗しました" }
  if ($out) { return ($out -join "`n" | ConvertFrom-Json) }
}

# BOM なし UTF-8 で一時ファイルに書く（Windows PowerShell の既定は BOM 付きで、aws CLI が読めないことがある）
function Write-JsonFile([object]$obj) {
  $path = [System.IO.Path]::GetTempFileName()
  $json = $obj | ConvertTo-Json -Depth 10 -Compress
  [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding $false))
  return $path
}

$account = (Invoke-Aws sts get-caller-identity).Account

if ($Sync) {
  $bucket = "$Project-results-$account"
  $dest = Join-Path (Split-Path $PSScriptRoot -Parent) "results"
  & aws s3 sync "s3://$bucket/runs/" $dest --region $Region
  Write-Host "結果: $dest"
  return
}

if ($Exec) { $Lab = "idle" }
if (-not $Lab) { throw "lab に渡すコマンドを指定してください（例: 'sweep --scenario s1'）。-Exec / -Sync も使えます" }
# 空白で区切る。ダブルクォートで囲んだ部分は1つの引数にする（"1 2 4" など）
$LabArgs = @([regex]::Matches($Lab, '"[^"]*"|\S+') | ForEach-Object { $_.Value.Trim('"') })

# base スタックが作ったネットワークを名前で引く
$subnet = (Invoke-Aws ec2 describe-subnets --filters "Name=tag:Name,Values=$Project-public-a").Subnets[0].SubnetId
$sg = (Invoke-Aws ec2 describe-security-groups --filters "Name=group-name,Values=$Project-loadgen").SecurityGroups[0].GroupId
if (-not $subnet -or -not $sg) { throw "base スタックのサブネット / SG が見つかりません" }

$network = Write-JsonFile @{ awsvpcConfiguration = @{ subnets = @($subnet); securityGroups = @($sg); assignPublicIp = "ENABLED" } }
$overrides = Write-JsonFile @{ containerOverrides = @(@{ name = "loadgen"; command = @($LabArgs) }) }

$runArgs = @("ecs", "run-task", "--cluster", $Cluster, "--task-definition", $Family, "--launch-type", "FARGATE",
  "--network-configuration", "file://$network", "--overrides", "file://$overrides", "--started-by", "loadgen.ps1")
if ($Exec) { $runArgs += "--enable-execute-command" }

Write-Host "起動: lab $($LabArgs -join ' ')"
$res = Invoke-Aws @runArgs
Remove-Item $network, $overrides
if ($res.failures.Count -gt 0) { throw "run-task 失敗: $($res.failures | ConvertTo-Json -Compress)" }
$taskArn = $res.tasks[0].taskArn
$taskId = $taskArn.Split("/")[-1]
Write-Host "タスク: $taskId"

$stream = "loadgen/loadgen/$taskId"
Write-Host "ログ:   aws logs tail $LogGroup --log-stream-names $stream --follow --region $Region"
Write-Host "停止:   aws ecs stop-task --cluster $Cluster --task $taskId --region $Region"

if ($Exec -or $Follow) {
  Write-Host "起動を待っています（1分前後）..."
  & aws ecs wait tasks-running --cluster $Cluster --tasks $taskArn --region $Region
  if ($LASTEXITCODE -ne 0) { throw "タスクが RUNNING になりませんでした。ECS コンソールで停止理由を確認してください" }
}

if ($Exec) {
  Write-Host ""
  Write-Host "入る: aws ecs execute-command --cluster $Cluster --task $taskId --container loadgen --interactive --command /bin/bash --region $Region"
  Write-Host "中で: lab sql a / lab sums / lab check / lab xa-recover ...（待機は IDLE_MAX_SECONDS=3600 秒で自動終了）"
}
elseif ($Follow) {
  # ログを流し続ける。最後に "done:" が出たら計測は終わり。Ctrl+C で表示だけ止まる（タスクは動き続ける）
  & aws logs tail $LogGroup --log-stream-names $stream --follow --region $Region
}
