-- 負荷側の上限確認: DB にほぼ仕事をさせずに、負荷タスクが出せる最大 QPS を測る
function thread_init()
  drv = sysbench.sql.driver()
  con = drv:connect()
end

function event()
  con:query("SELECT 1")
end

function thread_done()
  con:disconnect()
end
