<?php
/**
 * アイテムトレードを繰り返すワーカー（シナリオ4・XA）。lab trade が N 本並べて起動する。
 *
 * トレード = 「売り手のアイテムを買い手に渡し、買い手は売り手に代金（ゴールド）を払う」
 *   - 2人が同じシャードにいれば、1トランザクションで終わる
 *   - 別のシャードにいると、売り手側と買い手側の2つの DB を更新することになる。ここが難しいところ
 *
 * 使い方（ふつうは lab trade 経由で呼ぶ）:
 *   php trade.php --mode=naive|xa --seconds=60 --worker=1 --rows=100000
 *                 [--order=seller-first|buyer-first]   素朴版で、どちらのシャードを先に更新するか
 *                 [--fault=none|crash-between|crash-after-prepare|missing-buyer] [--fault-at=50] [--compensate]
 *
 * 接続先は lab と同じ環境変数（SHARDS, DB_HOSTS, DB_USER, DB_NAME, DB_PASSWORD_A ...）。
 * 終わると集計を JSON で1行、標準出力に出す。わざと落ちたときは何も出さない（それも結果のうち）。
 */

declare(strict_types=1);

// ------------------------------------------------------------ 引数と設定
$opt = getopt('', ['mode:', 'seconds:', 'worker:', 'rows:', 'order:', 'fault:', 'fault-at:', 'compensate']);
$mode       = $opt['mode'] ?? 'naive';
$seconds    = (int)($opt['seconds'] ?? 60);
$worker     = (int)($opt['worker'] ?? 1);
$rows       = (int)($opt['rows'] ?? 100000);
$order      = $opt['order'] ?? 'seller-first';
$fault      = $opt['fault'] ?? 'none';
$faultAt    = (int)($opt['fault-at'] ?? 50);   // 何回目のクロスシャードトレードで障害を起こすか
$compensate = isset($opt['compensate']);       // missing-buyer のとき、売り手側の変更を取り消す（補償処理）

if (!in_array($mode, ['naive', 'xa'], true)) fail("--mode は naive か xa");
if (!in_array($order, ['seller-first', 'buyer-first'], true)) fail("--order は seller-first か buyer-first");
if (!in_array($fault, ['none', 'crash-between', 'crash-after-prepare', 'missing-buyer'], true)) fail("--fault が不正: $fault");
if ($fault === 'crash-between' && $mode !== 'naive') fail('crash-between は --mode naive 用');
if ($fault === 'crash-after-prepare' && $mode !== 'xa') fail('crash-after-prepare は --mode xa 用');
if ($compensate && ($mode !== 'naive' || $order !== 'seller-first')) fail('--compensate は --mode naive --order seller-first 用');
if ($faultAt < 1) fail('--fault-at は 1 以上');

function fail(string $msg): never
{
    fwrite(STDERR, "trade.php: $msg\n");
    exit(2);
}

function logmsg(string $msg): void
{
    global $worker;
    fwrite(STDERR, sprintf("[%s w%d] %s\n", gmdate('H:i:s'), $worker, $msg));
}

// ------------------------------------------------------------ シャードの振り分け（ルーター）
// NewSQL なら不要な部分。アプリが「このプレイヤーはどの DB にいるか」を自分で知っている必要がある
final class Router
{
    /** @var string[] */ private array $keys;
    /** @var string[] */ private array $hosts;
    /** @var array<int, PDO> */ private array $pdo = [];

    public function __construct()
    {
        $this->keys  = explode(',', getenv('SHARDS') ?: 'a');
        $this->hosts = explode(',', getenv('DB_HOSTS') ?: '127.0.0.1');
        if (count($this->keys) !== count($this->hosts)) fail('SHARDS と DB_HOSTS の数が合わない');
    }

    public function count(): int
    {
        return count($this->keys);
    }

    /** プレイヤーがいるシャードの番号（0 始まり）。lab prepare と同じ規則 */
    public function shardOf(int $playerId): int
    {
        return ($playerId - 1) % $this->count();
    }

    public function name(int $shard): string
    {
        return strtoupper($this->keys[$shard]);
    }

    /** シャードへの接続。切れていたら（ネットワーク断・再起動の後）つなぎ直す */
    public function db(int $shard): PDO
    {
        if (!isset($this->pdo[$shard])) {
            [$host, $port] = array_pad(explode(':', $this->hosts[$shard]), 2, '3306');
            $key = strtoupper($this->keys[$shard]);
            $password = getenv("DB_PASSWORD_$key") ?: (getenv('DB_PASSWORD') ?: '');
            $dsn = sprintf('mysql:host=%s;port=%s;dbname=%s', $host, $port, getenv('DB_NAME') ?: 'lab');
            $pdo = new PDO($dsn, getenv('DB_USER') ?: 'admin', $password, [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_TIMEOUT => 5,
            ]);
            // ロック待ちは短めに（XA で固まった行に当たったとき、待ち続けずにエラーで分かるように）
            $pdo->exec('SET SESSION innodb_lock_wait_timeout = ' . (int)(getenv('LOCK_WAIT_TIMEOUT') ?: 5));
            $this->pdo[$shard] = $pdo;
        }
        return $this->pdo[$shard];
    }

    public function forget(int $shard): void
    {
        unset($this->pdo[$shard]);
    }
}

/** 2つのシャードのうち片方だけが確定した（または分からない）。整合性が崩れた可能性がある */
final class HalfDone extends RuntimeException
{
}

/** XA の第2段階（COMMIT）が途中で失敗した。準備済みのまま残った側を後から XA RECOVER で COMMIT する必要がある */
final class XaInDoubt extends RuntimeException
{
}

/** トレードを続けられない理由（業務的な失敗。DB の障害とは分ける） */
final class TradeRejected extends RuntimeException
{
}

// ------------------------------------------------------------ 共通の部品
function uuid(): string
{
    $b = random_bytes(16);
    $b[6] = chr((ord($b[6]) & 0x0f) | 0x40);
    $b[8] = chr((ord($b[8]) & 0x3f) | 0x80);
    return vsprintf('%s%s-%s-%s-%s-%s%s%s', str_split(bin2hex($b), 4));
}

/** わざと落ちる。kill -9 と同じで、後始末（ROLLBACK や接続の正常な切断）は一切しない */
function crash(string $where): never
{
    logmsg("障害注入: $where で強制終了（SIGKILL）");
    if (function_exists('posix_kill')) {
        posix_kill(getmypid(), SIGKILL);
    }
    exit(137);
}

function logRow(PDO $db, string $tradeId, string $side, int $seller, int $buyer, int $item, int $price): void
{
    $db->prepare('INSERT INTO trade_log (trade_id, side, seller, buyer, item_uid, price, created_at)
                  VALUES (?, ?, ?, ?, ?, ?, NOW(6))')
       ->execute([$tradeId, $side, $seller, $buyer, $item, $price]);
}

// --- 売り手側の更新: アイテムを手放し、代金を受け取る
function sellerSide(PDO $db, string $tradeId, int $seller, int $buyer, int $item, int $price): void
{
    $st = $db->prepare('SELECT owner_id FROM items WHERE item_uid = ? FOR UPDATE');
    $st->execute([$item]);
    if ((int)$st->fetchColumn() !== $seller) {
        throw new TradeRejected('売り手がもうそのアイテムを持っていない');
    }
    $db->prepare('DELETE FROM items WHERE item_uid = ?')->execute([$item]);
    $db->prepare('UPDATE players SET gold = gold + ?, updated_at = NOW() WHERE player_id = ?')->execute([$price, $seller]);
    logRow($db, $tradeId, 'seller', $seller, $buyer, $item, $price);
}

// --- 買い手側の更新: 代金を払い、アイテムを受け取る
function buyerSide(PDO $db, string $tradeId, int $seller, int $buyer, int $item, int $price, string $itemType): void
{
    $st = $db->prepare('UPDATE players SET gold = gold - ?, updated_at = NOW() WHERE player_id = ? AND gold >= ?');
    $st->execute([$price, $buyer, $price]);
    if ($st->rowCount() !== 1) {
        throw new TradeRejected('買い手がいない、またはゴールドが足りない');
    }
    $db->prepare('INSERT INTO items (item_uid, owner_id, item_type) VALUES (?, ?, ?)')->execute([$item, $buyer, $itemType]);
    logRow($db, $tradeId, 'buyer', $seller, $buyer, $item, $price);
}

// ------------------------------------------------------------ トレードの3つの書き方

/** 同じシャード同士: ふつうのトランザクション1つ。途中で落ちても全部取り消される */
function tradeSameShard(PDO $db, string $tradeId, int $seller, int $buyer, int $item, int $price): void
{
    $db->beginTransaction();
    try {
        $st = $db->prepare('SELECT owner_id FROM items WHERE item_uid = ? FOR UPDATE');
        $st->execute([$item]);
        if ((int)$st->fetchColumn() !== $seller) throw new TradeRejected('売り手がもうそのアイテムを持っていない');
        // デッドロックを避けるため、プレイヤーの行は id の小さい順にロックする
        $db->prepare('SELECT player_id FROM players WHERE player_id IN (?, ?) ORDER BY player_id FOR UPDATE')
           ->execute([min($seller, $buyer), max($seller, $buyer)]);
        $st = $db->prepare('UPDATE players SET gold = gold - ?, updated_at = NOW() WHERE player_id = ? AND gold >= ?');
        $st->execute([$price, $buyer, $price]);
        if ($st->rowCount() !== 1) throw new TradeRejected('買い手のゴールドが足りない');
        $db->prepare('UPDATE players SET gold = gold + ?, updated_at = NOW() WHERE player_id = ?')->execute([$price, $seller]);
        $db->prepare('UPDATE items SET owner_id = ? WHERE item_uid = ?')->execute([$buyer, $item]);
        logRow($db, $tradeId, 'same', $seller, $buyer, $item, $price);
        $db->commit();
    } catch (Throwable $e) {
        if ($db->inTransaction()) $db->rollBack();
        throw $e;
    }
}

/**
 * 別シャード・素朴版: 2つのシャードを順番に COMMIT する。
 *   seller-first: 売り手側（アイテムを消す）を COMMIT → 買い手側（アイテムを作る）を COMMIT。間で落ちると「消失」
 *   buyer-first : 売り手のアイテムをロックしてから、買い手側（アイテムを作る）を COMMIT → 売り手側（アイテムを消す）を COMMIT。
 *                 間で落ちると、売り手側は ROLLBACK されてアイテムが残るので「増殖」
 * どちらも最初に売り手のアイテムを FOR UPDATE でロックするので、落ちなければ同じアイテムが二重に売られることはない
 */
function tradeNaive(Router $r, string $tradeId, int $seller, int $buyer, int $item, int $price, string $itemType,
                    string $order, bool $crashBetween, bool $compensate): void
{
    $sellerDb = $r->db($r->shardOf($seller));
    $buyerDb  = $r->db($r->shardOf($buyer));

    if ($order === 'seller-first') {
        // 1つ目: 売り手側を確定する
        $sellerDb->beginTransaction();
        try {
            sellerSide($sellerDb, $tradeId, $seller, $buyer, $item, $price);
            $sellerDb->commit();
        } catch (Throwable $e) {
            if ($sellerDb->inTransaction()) $sellerDb->rollBack();
            throw $e;               // 何も確定していないので、ただの失敗
        }
        // ここで売り手側は確定済み。もう取り消せない
        if ($crashBetween) crash('売り手側の COMMIT 直後（seller-first）');

        // 2つ目: 買い手側
        $buyerDb->beginTransaction();
        try {
            buyerSide($buyerDb, $tradeId, $seller, $buyer, $item, $price, $itemType);
            $buyerDb->commit();
        } catch (TradeRejected $e) {
            $buyerDb->rollBack();
            // 業務エラー（買い手がいない等）。補償処理が無ければ売り手側の変更がそのまま残る
            if ($compensate) {
                compensateSeller($sellerDb, $tradeId, $seller, $item, $price, $itemType);
                throw new TradeRejected('買い手側で失敗したので、売り手側を補償処理で元に戻した');
            }
            throw new HalfDone('買い手側で失敗。売り手側は確定したまま: ' . $e->getMessage());
        } catch (Throwable $e) {
            if ($buyerDb->inTransaction()) { try { $buyerDb->rollBack(); } catch (Throwable) {} }
            // ネットワーク断・再起動など。買い手側が反映されたかどうかも分からない
            throw new HalfDone('買い手側で DB エラー（反映されたか不明）: ' . $e->getMessage());
        }
        return;
    }

    // buyer-first: 先に売り手のアイテムをロックして、売り手側のトランザクションを開いたままにする
    $sellerDb->beginTransaction();
    try {
        $st = $sellerDb->prepare('SELECT owner_id FROM items WHERE item_uid = ? FOR UPDATE');
        $st->execute([$item]);
        if ((int)$st->fetchColumn() !== $seller) throw new TradeRejected('売り手がもうそのアイテムを持っていない');

        // 1つ目: 買い手側を確定する（失敗したら売り手側も ROLLBACK するだけ。何も変わらない）
        $buyerDb->beginTransaction();
        try {
            buyerSide($buyerDb, $tradeId, $seller, $buyer, $item, $price, $itemType);
            $buyerDb->commit();
        } catch (Throwable $e) {
            if ($buyerDb->inTransaction()) $buyerDb->rollBack();
            throw $e;
        }
    } catch (Throwable $e) {
        if ($sellerDb->inTransaction()) $sellerDb->rollBack();
        throw $e;
    }
    // ここで買い手側は確定済み（アイテムが買い手にも存在する）
    if ($crashBetween) crash('買い手側の COMMIT 直後（buyer-first）');

    // 2つ目: 売り手側を確定する（ロックは握ったままなので、アイテムはまだ売り手のもの）
    try {
        $sellerDb->prepare('DELETE FROM items WHERE item_uid = ?')->execute([$item]);
        $sellerDb->prepare('UPDATE players SET gold = gold + ?, updated_at = NOW() WHERE player_id = ?')->execute([$price, $seller]);
        logRow($sellerDb, $tradeId, 'seller', $seller, $buyer, $item, $price);
        $sellerDb->commit();
    } catch (Throwable $e) {
        if ($sellerDb->inTransaction()) { try { $sellerDb->rollBack(); } catch (Throwable) {} }
        throw new HalfDone('売り手側で DB エラー。買い手側は確定したまま（アイテムが2つある可能性）: ' . $e->getMessage());
    }
}

/** 補償処理: 売り手側の変更を逆向きの操作で打ち消す（アイテムを戻し、代金を返す） */
function compensateSeller(PDO $db, string $tradeId, int $seller, int $item, int $price, string $itemType): void
{
    try {
        $db->beginTransaction();
        $db->prepare('INSERT INTO items (item_uid, owner_id, item_type) VALUES (?, ?, ?)')->execute([$item, $seller, $itemType]);
        $db->prepare('UPDATE players SET gold = gold - ?, updated_at = NOW() WHERE player_id = ?')->execute([$price, $seller]);
        $db->prepare('DELETE FROM trade_log WHERE trade_id = ? AND side = ?')->execute([$tradeId, 'seller']);
        $db->commit();
    } catch (Throwable $e) {
        if ($db->inTransaction()) { try { $db->rollBack(); } catch (Throwable) {} }
        // 補償処理そのものが失敗した。売り手側の変更は残ったまま
        throw new HalfDone('補償処理に失敗。売り手側は確定したまま: ' . $e->getMessage());
    }
}

/**
 * 別シャード・XA（2相コミット）版
 *   第1段階: 両方のシャードで更新して XA PREPARE（いつでも確定できる状態で保存。まだ確定はしない）
 *   第2段階: 両方 PREPARE できたら両方 XA COMMIT。どちらかが失敗したら両方 XA ROLLBACK
 * PREPARE の後に落ちると、両シャードに「準備済み」のトランザクションがロックを握ったまま残る（XA RECOVER で見える）
 */
function tradeXa(Router $r, string $tradeId, int $seller, int $buyer, int $item, int $price, string $itemType,
                 bool $crashAfterPrepare): void
{
    $sellerDb = $r->db($r->shardOf($seller));
    $buyerDb  = $r->db($r->shardOf($buyer));
    $xid = "'" . $tradeId . "'";    // uuid なので SQL に埋め込んでも安全
    $prepared = [];                 // PREPARE まで済んだシャードの接続

    // --- 第1段階
    try {
        foreach ([[$sellerDb, 'seller'], [$buyerDb, 'buyer']] as [$db, $side]) {
            $db->exec("XA START $xid");
            try {
                if ($side === 'seller') {
                    sellerSide($db, $tradeId, $seller, $buyer, $item, $price);
                } else {
                    buyerSide($db, $tradeId, $seller, $buyer, $item, $price, $itemType);
                }
                $db->exec("XA END $xid");
                $db->exec("XA PREPARE $xid");
            } catch (Throwable $e) {
                // このシャードは PREPARE 前（または PREPARE 失敗）なので、ここで取り消す
                try { $db->exec("XA END $xid"); } catch (Throwable) {}
                try { $db->exec("XA ROLLBACK $xid"); } catch (Throwable) {}
                throw $e;
            }
            $prepared[] = [$db, $side];
        }
    } catch (Throwable $e) {
        // 第1段階で失敗: PREPARE 済みの側も取り消して、何も起きなかったことにする
        foreach ($prepared as [$db, $side]) {
            try {
                $db->exec("XA ROLLBACK $xid");
            } catch (Throwable $re) {
                logmsg("XA ROLLBACK に失敗（$side 側に準備済みが残る。lab xa-recover で片付ける）: " . $re->getMessage());
            }
        }
        throw $e;
    }

    if ($crashAfterPrepare) crash('両シャードの XA PREPARE 直後（COMMIT 前）');

    // --- 第2段階: ここまで来たら必ず両方 COMMIT する。失敗した側は準備済みのまま残るので、後から XA RECOVER で COMMIT する
    $done = [];
    foreach ([[$sellerDb, 'seller'], [$buyerDb, 'buyer']] as [$db, $side]) {
        try {
            $db->exec("XA COMMIT $xid");
            $done[] = $side;
        } catch (Throwable $e) {
            throw new XaInDoubt(sprintf('XA COMMIT に失敗（%s 側。確定済み: %s）: %s',
                $side, $done ? implode(',', $done) : 'なし', $e->getMessage()));
        }
    }
}

// ------------------------------------------------------------ メインループ
$router = new Router();
$n = $router->count();
$counts = [
    'same_ok' => 0,          // 同じシャード同士で成功
    'cross_ok' => 0,         // 別シャードで成功
    'rejected' => 0,         // 業務的に不成立（アイテムが無い・ゴールド不足など）。何も変わっていない
    'half_done' => 0,        // 片方のシャードだけ確定した（または分からない）。整合性が崩れた可能性
    'db_error' => 0,         // 1つ目の更新前・XA の第1段階などで DB エラー。何も変わっていない
    'lock_timeout' => 0,     // ロック待ちタイムアウト（1205）。XA で固まった行に当たると増える
    'deadlock' => 0,         // デッドロック（1213）
    'dup_key' => 0,          // 主キー重複（1062）。同じアイテムが既にある = 増殖が起きている印
    'xa_in_doubt' => 0,      // XA の COMMIT が途中で失敗（ネットワーク断・再起動など）。準備済みが残る
];
$latency = ['same' => [], 'cross' => []];
$crossCount = 0;
$end = microtime(true) + $seconds;
mt_srand(random_int(1, PHP_INT_MAX));

while (microtime(true) < $end) {
    // 1. 売り手と買い手を選ぶ（自分とは取引しない）
    $seller = mt_rand(1, $rows);
    do { $buyer = mt_rand(1, $rows); } while ($buyer === $seller);
    $price = mt_rand(10, 100);
    $cross = $router->shardOf($seller) !== $router->shardOf($buyer);

    // 2. 売り手が持っているアイテムを1つ選ぶ（売り手のシャードに聞く）
    try {
        $st = $router->db($router->shardOf($seller))
            ->prepare('SELECT item_uid, item_type FROM items WHERE owner_id = ? LIMIT 1');
        $st->execute([$seller]);
        $row = $st->fetch(PDO::FETCH_NUM);
    } catch (PDOException $e) {
        $counts['db_error']++;
        $router->forget($router->shardOf($seller));
        usleep(200_000);
        continue;
    }
    if ($row === false) {
        $counts['rejected']++;
        continue;
    }
    [$item, $itemType] = [(int)$row[0], (string)$row[1]];

    // 3. 障害注入（ワーカー1だけ。--fault-at 回目のクロスシャードトレードで起こす）
    $inject = false;
    if ($cross) {
        $crossCount++;
        $inject = $worker === 1 && $fault !== 'none' && $crossCount % $faultAt === 0;
        if ($inject && $fault === 'missing-buyer') {
            $buyer += $rows * $n;       // 存在しないプレイヤー。シャード数の倍数を足すので、行き先のシャードは同じ
        }
    }

    // 4. トレード
    $tradeId = uuid();
    $t0 = hrtime(true);
    try {
        if (!$cross) {
            tradeSameShard($router->db($router->shardOf($seller)), $tradeId, $seller, $buyer, $item, $price);
        } elseif ($mode === 'naive') {
            tradeNaive($router, $tradeId, $seller, $buyer, $item, $price, $itemType, $order,
                $inject && $fault === 'crash-between', $compensate);
        } else {
            tradeXa($router, $tradeId, $seller, $buyer, $item, $price, $itemType,
                $inject && $fault === 'crash-after-prepare');
        }
        $counts[$cross ? 'cross_ok' : 'same_ok']++;
        $latency[$cross ? 'cross' : 'same'][] = (hrtime(true) - $t0) / 1e6;
    } catch (TradeRejected $e) {
        $counts['rejected']++;
    } catch (XaInDoubt $e) {
        $counts['xa_in_doubt']++;
        logmsg("XA 未確定 trade=$tradeId: " . $e->getMessage());
        foreach ([$router->shardOf($seller), $router->shardOf($buyer)] as $s) $router->forget($s);
    } catch (HalfDone $e) {
        $counts['half_done']++;
        logmsg("片側だけ確定 trade=$tradeId seller=$seller buyer=$buyer item=$item: " . $e->getMessage());
        foreach ([$router->shardOf($seller), $router->shardOf($buyer)] as $s) $router->forget($s);
    } catch (PDOException $e) {
        $code = (int)($e->errorInfo[1] ?? 0);
        if ($code === 1205) {
            $counts['lock_timeout']++;
        } elseif ($code === 1213) {
            $counts['deadlock']++;
        } elseif ($code === 1062) {
            $counts['dup_key']++;
        } else {
            $counts['db_error']++;
            logmsg("DB エラー: " . $e->getMessage());
            foreach ([$router->shardOf($seller), $router->shardOf($buyer)] as $s) $router->forget($s);
            usleep(200_000);
        }
    }
}

function pct(array $v, float $p): ?float
{
    if (!$v) return null;
    sort($v);
    return round($v[(int)min(count($v) - 1, ceil(count($v) * $p) - 1)], 2);
}

echo json_encode($counts + [
    'worker' => $worker,
    'same_p95_ms' => pct($latency['same'], 0.95),
    'same_p99_ms' => pct($latency['same'], 0.99),
    'cross_p95_ms' => pct($latency['cross'], 0.95),
    'cross_p99_ms' => pct($latency['cross'], 0.99),
], JSON_UNESCAPED_UNICODE), "\n";
