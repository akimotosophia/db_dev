#!/usr/bin/env python3
"""
I/O競合下 + パーティション構成での最新レコード取得ベンチマーク

測定内容:
  1. バックグラウンドSeqScanワーカー数を変えてI/O競合を再現
  2. 通常テーブル vs HASH partition vs RANGE partition での比較
"""

import subprocess, threading, time, statistics, textwrap
from concurrent.futures import ThreadPoolExecutor

DSN = "host=localhost port=5432 user=admin password=password dbname=bench_db"
PSQL = ["psql", f"postgresql://admin:password@localhost:5432/bench_db",
        "-t", "-A"]

def run_sql(sql, timeout=120):
    r = subprocess.run(PSQL + ["-c", sql],
                       capture_output=True, text=True, timeout=timeout)
    return r.stdout.strip(), r.stderr.strip()

def run_sql_ms(sql, n_runs=3):
    """クエリをn回実行して実行時間(ms)リストを返す"""
    times = []
    for _ in range(n_runs):
        plan_sql = f"EXPLAIN (ANALYZE, FORMAT JSON) {sql}"
        out, err = run_sql(plan_sql, timeout=180)
        if err and "ERROR" in err:
            print(f"  ERROR: {err[:120]}")
            return []
        import json
        plan = json.loads(out)
        times.append(plan[0]["Execution Time"])
    return times

# ──────────────────────────────────────────────
# バックグラウンドI/O負荷ワーカー
# ──────────────────────────────────────────────
stop_flag = threading.Event()

def io_worker():
    """product_prices を繰り返しSeqScanしてI/O圧力をかける"""
    noise_sql = ("SELECT SUM(price) FROM product_prices "
                 "WHERE effective_date > '2000-01-01'")
    while not stop_flag.is_set():
        run_sql(noise_sql, timeout=60)

# ──────────────────────────────────────────────
# クエリ定義
# ──────────────────────────────────────────────
def queries(table="product_prices"):
    return {
        "DISTINCT_ON": f"""
            SELECT DISTINCT ON (product_id) product_id, effective_date, price
            FROM {table}
            ORDER BY product_id, effective_date DESC""",
        "ROW_NUMBER": f"""
            SELECT product_id, effective_date, price
            FROM (
                SELECT product_id, effective_date, price,
                    ROW_NUMBER() OVER (
                        PARTITION BY product_id ORDER BY effective_date DESC
                    ) rn
                FROM {table}
            ) t WHERE rn = 1""",
        "RCTE": f"""
            WITH RECURSIVE skip AS (
                (SELECT product_id, effective_date, price
                 FROM {table}
                 ORDER BY product_id, effective_date DESC LIMIT 1)
                UNION ALL
                SELECT nxt.product_id, nxt.effective_date, nxt.price
                FROM skip
                CROSS JOIN LATERAL (
                    SELECT p.product_id, p.effective_date, p.price
                    FROM {table} p
                    WHERE p.product_id > skip.product_id
                    ORDER BY p.product_id, p.effective_date DESC LIMIT 1
                ) nxt
            )
            SELECT * FROM skip""",
    }

# ──────────────────────────────────────────────
# セットアップ: インデックス作成・パーティションテーブル構築
# ──────────────────────────────────────────────
def setup():
    print("== セットアップ中 ==")

    # 通常テーブルのインデックス
    run_sql("DROP INDEX IF EXISTS idx_pp_pid_date;")
    run_sql("CREATE INDEX idx_pp_pid_date ON product_prices(product_id, effective_date DESC);")
    print("  通常テーブル インデックス作成済み")

    # ── HASH パーティション (8分割) ──
    run_sql("DROP TABLE IF EXISTS pp_hash CASCADE;")
    run_sql("""
        CREATE TABLE pp_hash (
            id             BIGINT,
            product_id     INT       NOT NULL,
            effective_date DATE      NOT NULL,
            price          NUMERIC(10,2) NOT NULL
        ) PARTITION BY HASH (product_id);
    """)
    for i in range(8):
        run_sql(f"""
            CREATE TABLE pp_hash_{i}
            PARTITION OF pp_hash
            FOR VALUES WITH (MODULUS 8, REMAINDER {i});
        """)
    run_sql("INSERT INTO pp_hash SELECT id, product_id, effective_date, price FROM product_prices;")
    run_sql("CREATE INDEX idx_pphash_pid_date ON pp_hash(product_id, effective_date DESC);")
    run_sql("ANALYZE pp_hash;")
    print("  HASH partition (8) 作成済み")

    # ── RANGE パーティション (年別: 2020〜2025) ──
    run_sql("DROP TABLE IF EXISTS pp_range CASCADE;")
    run_sql("""
        CREATE TABLE pp_range (
            id             BIGINT,
            product_id     INT       NOT NULL,
            effective_date DATE      NOT NULL,
            price          NUMERIC(10,2) NOT NULL
        ) PARTITION BY RANGE (effective_date);
    """)
    for y in range(2020, 2026):
        run_sql(f"""
            CREATE TABLE pp_range_{y}
            PARTITION OF pp_range
            FOR VALUES FROM ('{y}-01-01') TO ('{y+1}-01-01');
        """)
    run_sql("INSERT INTO pp_range SELECT id, product_id, effective_date, price FROM product_prices;")
    run_sql("CREATE INDEX idx_pprange_pid_date ON pp_range(product_id, effective_date DESC);")
    run_sql("ANALYZE pp_range;")
    print("  RANGE partition (年別2020-2025) 作成済み")
    print()

# ──────────────────────────────────────────────
# ベンチマーク実行
# ──────────────────────────────────────────────
results = []

def bench(label, table, n_workers, n_runs=3):
    qs = queries(table)
    # インデックスの有無はテーブル側で制御済み
    for method, sql in qs.items():
        # HASH/RANGEテーブルはインデックスあり固定
        # 通常テーブルはインデックスなし/あり両方計測
        idx_variants = (
            [True] if table != "product_prices"
            else [False, True]
        )
        for has_idx in idx_variants:
            if table == "product_prices":
                if has_idx:
                    run_sql("CREATE INDEX IF NOT EXISTS idx_pp_pid_date "
                            "ON product_prices(product_id, effective_date DESC);")
                else:
                    run_sql("DROP INDEX IF EXISTS idx_pp_pid_date;")
                # RCTEはインデックスなしで計測しない（前回確認済みでO(n²)）
                if method == "RCTE" and not has_idx:
                    continue

            times = run_sql_ms(sql.strip(), n_runs=n_runs)
            if not times:
                continue
            median = statistics.median(times)
            idx_label = "IDX有" if has_idx else "IDX無"
            results.append({
                "label": label,
                "table": table,
                "workers": n_workers,
                "method": method,
                "idx": idx_label,
                "median_ms": round(median, 1),
                "times": [round(t, 1) for t in times],
            })
            print(f"  {label:18s} | {method:11s} | {idx_label} | "
                  f"{n_workers}workers | {round(median,0):6.0f}ms  {[round(t,0) for t in times]}")

def run_with_workers(n_workers, n_runs=3):
    global stop_flag
    stop_flag = threading.Event()

    workers = []
    for _ in range(n_workers):
        t = threading.Thread(target=io_worker, daemon=True)
        t.start()
        workers.append(t)

    if n_workers > 0:
        time.sleep(1)  # ワーカーが走り始めるまで待機

    try:
        for table, label in [
            ("product_prices", "通常テーブル"),
            ("pp_hash",        "HASH partition"),
            ("pp_range",       "RANGE partition"),
        ]:
            bench(label, table, n_workers, n_runs=n_runs)
    finally:
        stop_flag.set()

# ──────────────────────────────────────────────
# メイン
# ──────────────────────────────────────────────
if __name__ == "__main__":
    setup()

    # インデックスを通常テーブルに戻す
    run_sql("CREATE INDEX IF NOT EXISTS idx_pp_pid_date "
            "ON product_prices(product_id, effective_date DESC);")

    for n in [0, 2, 4]:
        print(f"\n{'='*60}")
        print(f"  I/O競合ワーカー数: {n}")
        print(f"{'='*60}")
        run_with_workers(n, n_runs=3)

    # ──── 結果サマリ ────
    print("\n\n" + "="*80)
    print("  結果サマリ")
    print("="*80)
    print(f"{'テーブル':20s}{'手法':13s}{'IDX':7s}{'workers':9s}{'中央値(ms)':>12s}")
    print("-"*80)

    last_w = None
    for r in results:
        if last_w != r["workers"]:
            last_w = r["workers"]
            print(f"\n  --- I/O競合ワーカー: {last_w}本 ---")
        print(f"  {r['label']:18s}  {r['method']:11s}  {r['idx']:6s}  "
              f"{r['workers']:2d}workers  {r['median_ms']:>9.1f} ms")

    # ワーカー数増加による劣化率
    print("\n\n" + "="*80)
    print("  I/O競合による劣化率 (workers=0 を 1.00 として)")
    print("="*80)
    baseline = {(r["label"], r["method"], r["idx"]): r["median_ms"]
                for r in results if r["workers"] == 0}
    print(f"{'テーブル':20s}{'手法':13s}{'IDX':7s}  {'w=0':>8s}  {'w=2':>8s}  {'w=4':>8s}  {'w=4倍率':>8s}")
    print("-"*80)
    seen = set()
    for r in sorted(results, key=lambda x: (x["label"], x["method"], x["idx"])):
        key = (r["label"], r["method"], r["idx"])
        if key in seen:
            continue
        seen.add(key)
        base = baseline.get(key)
        if not base:
            continue
        row = {rr["workers"]: rr["median_ms"] for rr in results if
               (rr["label"], rr["method"], rr["idx"]) == key}
        w0 = row.get(0, 0)
        w2 = row.get(2, 0)
        w4 = row.get(4, 0)
        ratio = w4 / w0 if w0 else 0
        print(f"  {r['label']:18s}  {r['method']:11s}  {r['idx']:6s}"
              f"  {w0:>8.1f}  {w2:>8.1f}  {w4:>8.1f}  {ratio:>7.2f}x")
