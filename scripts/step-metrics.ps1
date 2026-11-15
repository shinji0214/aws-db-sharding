<#
.SYNOPSIS
  sweep の段階ごとに、DB 側のメトリクスと待機イベントを取り出して表にする。db を destroy する前に手元PCで実行する。

.DESCRIPTION
  results\<run_id>\summary.csv（loadgen.ps1 -Sync で落としたもの）の各段階の start_utc〜end_utc について、
  - CloudWatch: CPUUtilization / CommitLatency / DatabaseConnections の平均
  - Database Insights: DB Load（db.load.avg）の平均と、待機イベントの上位
  を取り、results\<run_id>\step-metrics-<shard>.csv と step-waits-<shard>.csv に書く。画面には段階ごとの要約を出す。
  Database Insights のデータはインスタンスを消すと見られなくなるので、必ず destroy の前に流す。

.EXAMPLE
  .\scripts\loadgen.ps1 -Sync
  .\scripts\step-metrics.ps1 20261115T063908Z-s1-1shard-db.t4g.medium
  # 2シャードのとき（シャードごとに1回ずつ）
  .\scripts\step-metrics.ps1 <run_id> -Shard b
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$RunId,
  [string]$Shard = "a",
  # 待機イベントを何位まで残すか
  [int]$Top = 5,
  [string]$Project = "db-sharding-aws",
  [string]$Region = "ap-northeast-1"
)

$ErrorActionPreference = "Stop"

function Invoke-Aws {
  $out = & aws @args --region $Region --output json
  if ($LASTEXITCODE -ne 0) { throw "aws $($args -join ' ') が失敗しました" }
  if ($out) { return ($out -join "`n" | ConvertFrom-Json) }
}

$root = Split-Path $PSScriptRoot -Parent
$dir = Join-Path (Join-Path $root "results") $RunId
$summary = Join-Path $dir "summary.csv"
if (-not (Test-Path $summary)) { throw "$summary がありません。先に .\scripts\loadgen.ps1 -Sync を実行してください" }

$instance = "$Project-$Shard-1"
$rid = (Invoke-Aws rds describe-db-instances --db-instance-identifier $instance).DBInstances[0].DbiResourceId
Write-Host "インスタンス: $instance"

# CloudWatch の1つのメトリクスの、期間内の平均（1分値の平均）
function Get-CwAverage([string]$metric, [string]$start, [string]$end) {
  $res = Invoke-Aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name $metric `
    --dimensions "Name=DBInstanceIdentifier,Value=$instance" --start-time $start --end-time $end `
    --period 60 --statistics Average
  $vals = @($res.Datapoints | ForEach-Object { $_.Average })
  if ($vals.Count -eq 0) { return $null }
  return [math]::Round(($vals | Measure-Object -Average).Average, 2)
}

$metrics = @()
$waits = @()
$rows = Import-Csv $summary | Where-Object { $_.valid -notlike "skip*" }
$sty = [Globalization.DateTimeStyles]'AssumeUniversal,AdjustToUniversal'
foreach ($r in $rows) {
  # CloudWatch も Database Insights も分の境目に丸めて範囲を広げるので、そのままだと次の段階のウォームアップ（本数が多い）が
  # 混ざる。計測区間の内側の分単位に縮める（180 秒の計測なら、まるごと入る 2 分ぶん）
  $s = [datetime]::Parse($r.start_utc, [cultureinfo]::InvariantCulture, $sty)
  $e = [datetime]::Parse($r.end_utc, [cultureinfo]::InvariantCulture, $sty)
  if ($s.Second -gt 0) { $s = $s.AddSeconds(60 - $s.Second) }
  $e = $e.AddSeconds(-$e.Second)
  $start = $s.ToString("yyyy-MM-ddTHH:mm:ssZ")
  $end = $e.ToString("yyyy-MM-ddTHH:mm:ssZ")
  $cpu = Get-CwAverage "CPUUtilization" $start $end
  $commit = Get-CwAverage "CommitLatency" $start $end
  $conn = Get-CwAverage "DatabaseConnections" $start $end

  # DB Load の平均（Database Insights）。JSON を引数に書くと Windows PowerShell で " が消えるので shorthand 構文を使う
  $load = $null
  $lr = Invoke-Aws pi get-resource-metrics --service-type RDS --identifier $rid --start-time $start --end-time $end `
    --period-in-seconds 60 --metric-queries Metric=db.load.avg
  $pts = @($lr.MetricList[0].DataPoints | Where-Object { $_.PSObject.Properties.Name -contains "Value" } | ForEach-Object { $_.Value })
  if ($pts.Count -gt 0) { $load = [math]::Round(($pts | Measure-Object -Average).Average, 2) }

  $wr = Invoke-Aws pi describe-dimension-keys --service-type RDS --identifier $rid --start-time $start --end-time $end `
    --metric db.load.avg --group-by "Group=db.wait_event,Limit=$Top"
  $rank = 0
  $topText = @()
  foreach ($k in $wr.Keys) {
    $rank++
    $name = $k.Dimensions.'db.wait_event.name'
    $aas = [math]::Round([double]$k.Total, 3)
    $waits += [pscustomobject]@{ run_id = $RunId; shard = $Shard; step = $r.step; repeat = $r.repeat; threads = $r.threads_total; rank = $rank; wait_event = $name; aas = $aas }
    if ($rank -le 3) { $topText += "$name=$aas" }
  }

  # 1件あたり時間（リトルの法則: 全体の本数 ÷ 全体の TPS）。全シャードの平均で、シャードごとの値ではない
  $perTx = $null
  if ([double]$r.tps -gt 0) { $perTx = [math]::Round(1000.0 * [double]$r.threads_per_shard / ([double]$r.tps / [double]$r.shards), 2) }

  $metrics += [pscustomobject]@{
    run_id = $RunId; shard = $Shard; step = $r.step; repeat = $r.repeat; threads = $r.threads_total
    tps = $r.tps; per_tx_ms = $perTx; commit_latency_ms = $commit; db_cpu_pct = $cpu; db_connections = $conn
    db_load_aas = $load; start_utc = $start; end_utc = $end
  }
  Write-Host ("step{0} r{1} t={2,-4} tps={3,-9} 1件={4,-6}ms commit={5,-6}ms cpu={6,-6}% load={7,-5} {8}" -f `
      $r.step, $r.repeat, $r.threads_total, $r.tps, $perTx, $commit, $cpu, $load, ($topText -join " "))
}

$mPath = Join-Path $dir "step-metrics-$Shard.csv"
$wPath = Join-Path $dir "step-waits-$Shard.csv"
$metrics | Export-Csv -Path $mPath -NoTypeInformation -Encoding UTF8
$waits | Export-Csv -Path $wPath -NoTypeInformation -Encoding UTF8
Write-Host "保存: $mPath"
Write-Host "保存: $wPath"
