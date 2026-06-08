-- ============================================================
-- ベンチマーク: 最新有効日付レコード抽出
-- ROW_NUMBER() OVER (PARTITION BY) vs DISTINCT ON
-- ============================================================

\timing on

-- 結果格納テーブル
DROP TABLE IF EXISTS bench_results;
CREATE TABLE bench_results (
    data_size        BIGINT,
    method           TEXT,
    elapsed_ms       NUMERIC,
    planning_ms      NUMERIC,
    execution_ms     NUMERIC,
    rows_returned    BIGINT,
    seq_scans        BIGINT,
    index_scans      BIGINT,
    shared_hit       BIGINT,
    shared_read      BIGINT,
    tested_at        TIMESTAMPTZ DEFAULT NOW()
);

-- テスト対象テーブル
DROP TABLE IF EXISTS product_prices;
CREATE TABLE product_prices (
    id             BIGSERIAL PRIMARY KEY,
    product_id     INT         NOT NULL,
    effective_date DATE        NOT NULL,
    price          NUMERIC(10,2) NOT NULL,
    note           TEXT
);

-- インデックスなし／ありを切り替えるフラグは後で対応
-- まずはインデックスなしで計測、次にインデックスありで計測

-- ============================================================
-- データ生成関数
-- ============================================================
CREATE OR REPLACE FUNCTION generate_price_data(num_rows BIGINT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    TRUNCATE product_prices RESTART IDENTITY;

    INSERT INTO product_prices (product_id, effective_date, price, note)
    SELECT
        -- 商品IDは行数の約 1/10 種類
        (random() * (num_rows / 10))::INT + 1,
        -- 有効日付は過去3年以内のランダムな日付
        DATE '2022-01-01' + (random() * 1095)::INT,
        (random() * 10000 + 100)::NUMERIC(10,2),
        'note_' || i
    FROM generate_series(1, num_rows) AS s(i);
END;
$$;

-- ============================================================
-- 計測関数: DISTINCT ON
-- ============================================================
CREATE OR REPLACE FUNCTION bench_distinct_on(label TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    t0      TIMESTAMPTZ;
    elapsed NUMERIC;
    plan    JSONB;
    cnt     BIGINT;
    p_ms    NUMERIC;
    e_ms    NUMERIC;
    s_hit   BIGINT;
    s_read  BIGINT;
    s_seq   BIGINT;
    s_idx   BIGINT;
BEGIN
    -- バッファキャッシュの影響を減らすため統計リセット
    PERFORM pg_stat_reset();
    PERFORM pg_sleep(0.1);

    -- EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) で詳細取得
    EXECUTE $Q$
        EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
        SELECT DISTINCT ON (product_id)
            product_id, effective_date, price
        FROM product_prices
        ORDER BY product_id, effective_date DESC
    $Q$ INTO plan;

    p_ms   := (plan->0->'Planning Time')::NUMERIC;
    e_ms   := (plan->0->'Execution Time')::NUMERIC;
    cnt    := (plan->0->'Plan'->>'Actual Rows')::BIGINT;

    -- バッファ統計はトップノードから取得
    s_hit  := COALESCE((plan->0->'Plan'->'Shared Hit Blocks')::BIGINT, 0);
    s_read := COALESCE((plan->0->'Plan'->'Shared Read Blocks')::BIGINT, 0);

    -- テーブルスキャン統計
    SELECT COALESCE(seq_scan, 0), COALESCE(idx_scan, 0)
    INTO s_seq, s_idx
    FROM pg_stat_user_tables
    WHERE relname = 'product_prices';

    INSERT INTO bench_results
        (data_size, method, elapsed_ms, planning_ms, execution_ms,
         rows_returned, seq_scans, index_scans, shared_hit, shared_read)
    VALUES
        (label::BIGINT, 'DISTINCT ON', p_ms + e_ms, p_ms, e_ms,
         cnt, s_seq, s_idx, s_hit, s_read);
END;
$$;

-- ============================================================
-- 計測関数: ROW_NUMBER() PARTITION BY
-- ============================================================
CREATE OR REPLACE FUNCTION bench_row_number(label TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    plan    JSONB;
    cnt     BIGINT;
    p_ms    NUMERIC;
    e_ms    NUMERIC;
    s_hit   BIGINT;
    s_read  BIGINT;
    s_seq   BIGINT;
    s_idx   BIGINT;
BEGIN
    PERFORM pg_stat_reset();
    PERFORM pg_sleep(0.1);

    EXECUTE $Q$
        EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
        SELECT product_id, effective_date, price
        FROM (
            SELECT
                product_id, effective_date, price,
                ROW_NUMBER() OVER (
                    PARTITION BY product_id
                    ORDER BY effective_date DESC
                ) AS rn
            FROM product_prices
        ) ranked
        WHERE rn = 1
    $Q$ INTO plan;

    p_ms   := (plan->0->'Planning Time')::NUMERIC;
    e_ms   := (plan->0->'Execution Time')::NUMERIC;
    cnt    := (plan->0->'Plan'->>'Actual Rows')::BIGINT;

    s_hit  := COALESCE((plan->0->'Plan'->'Shared Hit Blocks')::BIGINT, 0);
    s_read := COALESCE((plan->0->'Plan'->'Shared Read Blocks')::BIGINT, 0);

    SELECT COALESCE(seq_scan, 0), COALESCE(idx_scan, 0)
    INTO s_seq, s_idx
    FROM pg_stat_user_tables
    WHERE relname = 'product_prices';

    INSERT INTO bench_results
        (data_size, method, elapsed_ms, planning_ms, execution_ms,
         rows_returned, seq_scans, index_scans, shared_hit, shared_read)
    VALUES
        (label::BIGINT, 'ROW_NUMBER', p_ms + e_ms, p_ms, e_ms,
         cnt, s_seq, s_idx, s_hit, s_read);
END;
$$;

-- ============================================================
-- メインベンチマーク: インデックスなし
-- ============================================================
DO $$
DECLARE
    sizes BIGINT[] := ARRAY[100000, 500000, 1000000, 3000000, 5000000, 10000000];
    sz    BIGINT;
BEGIN
    RAISE NOTICE '=== ベンチマーク開始: インデックスなし ===';
    FOREACH sz IN ARRAY sizes LOOP
        RAISE NOTICE '-- データ生成中: % 件', sz;
        PERFORM generate_price_data(sz);
        ANALYZE product_prices;

        RAISE NOTICE '  DISTINCT ON 計測中...';
        PERFORM bench_distinct_on(sz::TEXT);

        RAISE NOTICE '  ROW_NUMBER 計測中...';
        PERFORM bench_row_number(sz::TEXT);

        RAISE NOTICE '  完了: % 件', sz;
    END LOOP;
    RAISE NOTICE '=== インデックスなし完了 ===';
END $$;

-- ============================================================
-- (product_id, effective_date DESC) 複合インデックス付与
-- ============================================================
CREATE INDEX idx_product_prices_pid_date
    ON product_prices (product_id, effective_date DESC);

DO $$
DECLARE
    sizes BIGINT[] := ARRAY[100000, 500000, 1000000, 3000000, 5000000, 10000000];
    sz    BIGINT;
BEGIN
    RAISE NOTICE '=== ベンチマーク開始: インデックスあり ===';
    FOREACH sz IN ARRAY sizes LOOP
        RAISE NOTICE '-- データ生成中: % 件', sz;
        PERFORM generate_price_data(sz);
        ANALYZE product_prices;

        RAISE NOTICE '  DISTINCT ON 計測中...';
        PERFORM bench_distinct_on(sz::TEXT);

        RAISE NOTICE '  ROW_NUMBER 計測中...';
        PERFORM bench_row_number(sz::TEXT);

        RAISE NOTICE '  完了: % 件', sz;
    END LOOP;
    RAISE NOTICE '=== インデックスあり完了 ===';
END $$;

DROP INDEX IF EXISTS idx_product_prices_pid_date;

-- ============================================================
-- 結果サマリ表示
-- ============================================================
\pset format aligned
\pset tuples_only off

SELECT
    data_size                          AS "データ件数",
    method                             AS "手法",
    ROUND(planning_ms, 2)              AS "計画時間(ms)",
    ROUND(execution_ms, 2)             AS "実行時間(ms)",
    ROUND(execution_ms + planning_ms, 2) AS "合計(ms)",
    rows_returned                      AS "返却行数",
    shared_hit                         AS "バッファHit",
    shared_read                        AS "ディスクRead"
FROM bench_results
ORDER BY data_size, method;

-- ============================================================
-- 手法ごとの速度比較 (ROW_NUMBER を基準1.00)
-- ============================================================
WITH pivot AS (
    SELECT
        data_size,
        MAX(CASE WHEN method = 'DISTINCT ON' THEN execution_ms END) AS do_ms,
        MAX(CASE WHEN method = 'ROW_NUMBER'  THEN execution_ms END) AS rn_ms
    FROM bench_results
    GROUP BY data_size
)
SELECT
    data_size                           AS "データ件数",
    ROUND(do_ms, 1)                     AS "DISTINCT ON (ms)",
    ROUND(rn_ms, 1)                     AS "ROW_NUMBER (ms)",
    ROUND(do_ms / NULLIF(rn_ms, 0), 3)  AS "比率(DO/RN)",
    CASE
        WHEN do_ms < rn_ms * 0.95 THEN 'DISTINCT ON が速い'
        WHEN rn_ms < do_ms * 0.95 THEN 'ROW_NUMBER が速い'
        ELSE 'ほぼ同等'
    END                                 AS "判定"
FROM pivot
ORDER BY data_size;
