-- シナリオ1〜3: 自動コミットの UPDATE
--   既定        : ランダムなプレイヤーに経験値を1加算する（シナリオ1・2）
--   --boss=1    : 全員でワールドボス 1 の HP を1ずつ削る（シナリオ3 ホットスポット）
--   --batch=10  : 10件まとめてコミット（H2 の確認用）
-- シャード構成ではシャードごとに sysbench を1つずつ起動し、そのシャードにいるプレイヤーだけを更新する。
-- プレイヤーの居場所: シャード番号 = (player_id - 1) % シャード数。つまり player_id = shard_index + 1 + nshards * k
--   2シャードなら A = 奇数, B = 偶数（計画書のとおり）

sysbench.cmdline.options = {
  rows        = {"全シャード合計のプレイヤー数", 100000},
  nshards     = {"シャード数", 1},
  shard_index = {"このプロセスが受け持つシャード（0 始まり）", 0},
  boss        = {"0 より大きければ、プレイヤーではなくこのワールドボスの HP を削る（シナリオ3）", 0},
  batch       = {"1トランザクションあたりの UPDATE 件数（1 = 自動コミット）", 1},
}

function thread_init()
  drv = sysbench.sql.driver()
  con = drv:connect()
  n = sysbench.opt.nshards
  idx = sysbench.opt.shard_index
  batch = sysbench.opt.batch
  boss = sysbench.opt.boss
  -- このシャードにいるプレイヤー数（player_id = idx + 1 + n * k、k = 0 .. per - 1）
  per = math.floor((sysbench.opt.rows - (idx + 1)) / n) + 1
  if boss > 0 then
    stmt = con:prepare("UPDATE world_boss SET hp = hp - 1 WHERE boss_id = ?")
  else
    stmt = con:prepare("UPDATE players SET exp = exp + 1, updated_at = NOW() WHERE player_id = ?")
  end
  param = stmt:bind_create(sysbench.sql.type.BIGINT)
  stmt:bind_param(param)
end

local function next_id()
  if boss > 0 then
    return boss
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
