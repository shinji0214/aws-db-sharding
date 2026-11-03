-- シナリオ1〜3: users への自動コミット UPDATE
--   一様乱数（既定） / ホットスポット（--hot-id=1） / まとめてコミット（--batch=10、H2 の確認用）
-- シャード構成ではシャードごとに sysbench を1つずつ起動し、そのシャードが持つ ID だけを更新する。
-- ID の持ち主: id を (シャード数) で割った余りで決める。id = shard_index + 1 + nshards * k
--   2シャードなら a = 奇数, b = 偶数（計画書のとおり）

sysbench.cmdline.options = {
  rows        = {"全シャード合計の行数", 100000},
  nshards     = {"シャード数", 1},
  shard_index = {"このプロセスが受け持つシャード（0 始まり）", 0},
  hot_id      = {"0 より大きければ常にこの id を更新する（シナリオ3）", 0},
  batch       = {"1トランザクションあたりの UPDATE 件数（1 = 自動コミット）", 1},
}

function thread_init()
  drv = sysbench.sql.driver()
  con = drv:connect()
  n = sysbench.opt.nshards
  idx = sysbench.opt.shard_index
  batch = sysbench.opt.batch
  hot = sysbench.opt.hot_id
  -- このシャードが持つ行数（id = idx + 1 + n * k、k = 0 .. per - 1）
  per = math.floor((sysbench.opt.rows - (idx + 1)) / n) + 1
  stmt = con:prepare("UPDATE users SET score = score + 1, updated_at = NOW() WHERE id = ?")
  param = stmt:bind_create(sysbench.sql.type.BIGINT)
  stmt:bind_param(param)
end

local function next_id()
  if hot > 0 then
    return hot
  end
  return idx + 1 + n * sysbench.rand.uniform(0, per - 1)
end

function event()
  if batch > 1 then
    con:query("BEGIN")
  end
  for _ = 1, batch do
    param:set(next_id())
    stmt:execute()
  end
  if batch > 1 then
    con:query("COMMIT")
  end
end

function thread_done()
  stmt:close()
  con:disconnect()
end
