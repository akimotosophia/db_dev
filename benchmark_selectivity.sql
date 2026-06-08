-- ============================================================
-- selectivity ベンチマーク
-- 目的: 総行数に対する返却行数の比率 (rows/product) を変えて
--       インデックスの効果を検証する
--
-- シナリオ A: 全商品を一括取得 (rows_per_product を増やして確認)
--   - 10M 行 / 100K 商品 = 100 行/商品 → 返却 100K / 10M = 1%
--   - 10M 行 / 10K 商品  = 1000 行/商品 → 返却  10K / 10M = 0.1%
--
-- シナリオ B: WHERE で特定商品を絞り込んでから最新を取得
--   - 1 商品だけ指定 (最高選択性)
--   - 100 商品を指定
--   - 1000 商品を指定
-- ============================================================

\timing on

-- 結果格納
DROP TABLE IF EXISTS sel_results;
CREATE TABLE sel_results (
    scenario        TEXT,
    total_rows      BIGINT,
    num_products    BIGINT,
    rows_per_prod   BIGINT,
    result_rows     BIGINT,
    selectivity_pct NUMERIC,
    method          TEXT,
    has_index       BOOLEAN,
    execution_ms    NUMERIC,
    planning_ms     NUMERIC,
    buf_hit         BIGINT,
    disk_read       BIGINT,
    tested_at       TIMESTAMPTZ DEFAULT NOW()
);

-- テーブル再作成
DROP TABLE IF EXISTS product_prices;
CREATE TABLE product_prices (
    id             BIGSERIAL PRIMARY KEY,
    product_id     INT       NOT NULL,
    effective_date DATE      NOT NULL,
    price          NUMERIC(10,2) NOT NULL
);

-- ============================================================
-- データ生成 (num_products 指定版)
-- ============================================================
CREATE OR REPLACE FUNCTION gen_data(p_total BIGINT, p_products BIGINT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    TRUNCATE product_prices RESTART IDENTITY;
    INSERT INTO product_prices (product_id, effective_date, price)
    SELECT
        (random() * (p_products - 1))::INT + 1,
        DATE '2020-01-01' + (random() * 1826)::INT,
        (random() * 10000 + 100)::NUMERIC(10,2)
    FROM generate_series(1, p_total);
END;
$$;

-- ============================================================
-- 計測ヘルパー
-- ============================================================
CREATE OR REPLACE FUNCTION measure(
    p_scenario TEXT,
    p_total    BIGINT,
    p_prods    BIGINT,
    p_rpp      BIGINT,
    p_method   TEXT,
    p_has_idx  BOOLEAN,
    p_sql      TEXT
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    plan     JSONB;
    p_ms     NUMERIC;
    e_ms     NUMERIC;
    s_hit    BIGINT;
    s_read   BIGINT;
    ret_rows BIGINT;
BEGIN
    PERFORM pg_stat_reset();
    EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || p_sql INTO plan;

    p_ms     := (plan->0->>'Planning Time')::NUMERIC;
    e_ms     := (plan->0->>'Execution Time')::NUMERIC;
    ret_rows := (plan->0->'Plan'->>'Actual Rows')::BIGINT;
    s_hit    := COALESCE((plan->0->'Plan'->'Shared Hit Blocks')::BIGINT, 0);
    s_read   := COALESCE((plan->0->'Plan'->'Shared Read Blocks')::BIGINT, 0);

    INSERT INTO sel_results
      (scenario, total_rows, num_products, rows_per_prod, result_rows,
       selectivity_pct, method, has_index, execution_ms, planning_ms,
       buf_hit, disk_read)
    VALUES
      (p_scenario, p_total, p_prods, p_rpp, ret_rows,
       ROUND(ret_rows::NUMERIC / p_total * 100, 3),
       p_method, p_has_idx, e_ms, p_ms, s_hit, s_read);
END;
$$;

-- ============================================================
-- シナリオ A: 全商品一括取得 (rows/product 比率を変える)
-- 固定: 10M 行 / 可変: 商品数
-- ============================================================
DO $$
DECLARE
    total_rows  BIGINT  := 10000000;
    num_prods   BIGINT;
    rpp         BIGINT;
    sql_do      TEXT;
    sql_rn      TEXT;
BEGIN
    sql_do := $Q$
        SELECT DISTINCT ON (product_id)
            product_id, effective_date, price
        FROM product_prices
        ORDER BY product_id, effective_date DESC
    $Q$;

    sql_rn := $Q$
        SELECT product_id, effective_date, price
        FROM (
            SELECT product_id, effective_date, price,
                ROW_NUMBER() OVER (
                    PARTITION BY product_id ORDER BY effective_date DESC
                ) rn
            FROM product_prices
        ) t WHERE rn = 1
    $Q$;

    FOREACH num_prods IN ARRAY ARRAY[1000000, 100000, 10000]::BIGINT[] LOOP
        rpp := total_rows / num_prods;
        RAISE NOTICE '=== A: % 行 / % 商品 (% 行/商品) ===', total_rows, num_prods, rpp;

        PERFORM gen_data(total_rows, num_prods);
        ANALYZE product_prices;

        -- インデックスなし
        RAISE NOTICE '  インデックスなし...';
        PERFORM measure('A: 全商品一括', total_rows, num_prods, rpp,
                        'DISTINCT ON', false, sql_do);
        PERFORM measure('A: 全商品一括', total_rows, num_prods, rpp,
                        'ROW_NUMBER', false, sql_rn);

        -- インデックスあり
        CREATE INDEX tmp_idx ON product_prices (product_id, effective_date DESC);
        RAISE NOTICE '  インデックスあり...';
        PERFORM measure('A: 全商品一括', total_rows, num_prods, rpp,
                        'DISTINCT ON', true, sql_do);
        PERFORM measure('A: 全商品一括', total_rows, num_prods, rpp,
                        'ROW_NUMBER', true, sql_rn);
        DROP INDEX tmp_idx;
    END LOOP;
END $$;

-- ============================================================
-- シナリオ B: WHERE で絞り込み (10M 行 / 100K 商品 のテーブル)
-- 返却件数: 1商品, 100商品, 1000商品
-- ============================================================
DO $$
DECLARE
    total_rows BIGINT := 10000000;
    num_prods  BIGINT := 100000;
    rpp        BIGINT := 100;
    n_filter   BIGINT;
    sql_do     TEXT;
    sql_rn     TEXT;
BEGIN
    RAISE NOTICE '=== シナリオ B: WHERE 絞り込み (% 行 / % 商品) ===',
        total_rows, num_prods;

    PERFORM gen_data(total_rows, num_prods);
    ANALYZE product_prices;

    FOREACH n_filter IN ARRAY ARRAY[1, 100, 1000, 10000]::BIGINT[] LOOP
        RAISE NOTICE '  絞り込み商品数: %', n_filter;

        sql_do := format($Q$
            SELECT DISTINCT ON (product_id)
                product_id, effective_date, price
            FROM product_prices
            WHERE product_id <= %s
            ORDER BY product_id, effective_date DESC
        $Q$, n_filter);

        sql_rn := format($Q$
            SELECT product_id, effective_date, price
            FROM (
                SELECT product_id, effective_date, price,
                    ROW_NUMBER() OVER (
                        PARTITION BY product_id ORDER BY effective_date DESC
                    ) rn
                FROM product_prices
                WHERE product_id <= %s
            ) t WHERE rn = 1
        $Q$, n_filter);

        -- インデックスなし
        PERFORM measure('B: WHERE 絞り込み', total_rows, num_prods, rpp,
                        'DISTINCT ON', false, sql_do);
        PERFORM measure('B: WHERE 絞り込み', total_rows, num_prods, rpp,
                        'ROW_NUMBER', false, sql_rn);

        -- インデックスあり
        CREATE INDEX tmp_idx ON product_prices (product_id, effective_date DESC);
        PERFORM measure('B: WHERE 絞り込み', total_rows, num_prods, rpp,
                        'DISTINCT ON', true, sql_do);
        PERFORM measure('B: WHERE 絞り込み', total_rows, num_prods, rpp,
                        'ROW_NUMBER', true, sql_rn);
        DROP INDEX tmp_idx;
    END LOOP;
END $$;

-- ============================================================
-- 結果表示
-- ============================================================
\pset format aligned

-- シナリオ A
SELECT
    num_products            AS "商品数",
    rows_per_prod           AS "行/商品",
    ROUND(selectivity_pct, 2) AS "返却率(%)",
    method                  AS "手法",
    CASE has_index WHEN true THEN 'あり' ELSE 'なし' END AS "IDX",
    ROUND(execution_ms, 0)  AS "実行(ms)",
    disk_read               AS "ディスクRead"
FROM sel_results
WHERE scenario = 'A: 全商品一括'
ORDER BY num_products DESC, has_index, method;

-- シナリオ B
SELECT
    result_rows             AS "返却件数",
    ROUND(selectivity_pct, 3) AS "返却率(%)",
    method                  AS "手法",
    CASE has_index WHEN true THEN 'あり' ELSE 'なし' END AS "IDX",
    ROUND(execution_ms, 0)  AS "実行(ms)",
    disk_read               AS "ディスクRead"
FROM sel_results
WHERE scenario = 'B: WHERE 絞り込み'
ORDER BY result_rows, has_index, method;

-- 勝敗まとめ
WITH pivot AS (
    SELECT
        scenario, num_products, rows_per_prod, result_rows,
        ROUND(selectivity_pct, 3) AS sel_pct,
        method, has_index,
        execution_ms
    FROM sel_results
),
comp AS (
    SELECT
        p.scenario,
        p.num_products,
        p.rows_per_prod,
        p.result_rows,
        p.sel_pct,
        p.has_index,
        MAX(CASE WHEN p.method = 'DISTINCT ON' THEN execution_ms END) AS do_ms,
        MAX(CASE WHEN p.method = 'ROW_NUMBER'  THEN execution_ms END) AS rn_ms
    FROM pivot p
    GROUP BY p.scenario, p.num_products, p.rows_per_prod, p.result_rows,
             p.sel_pct, p.has_index
),
idx_comp AS (
    SELECT
        c.scenario,
        c.num_products,
        c.rows_per_prod,
        c.result_rows,
        c.sel_pct,
        MAX(CASE WHEN NOT c.has_index THEN do_ms END) AS do_noidx,
        MAX(CASE WHEN     c.has_index THEN do_ms END) AS do_idx,
        MAX(CASE WHEN NOT c.has_index THEN rn_ms END) AS rn_noidx,
        MAX(CASE WHEN     c.has_index THEN rn_ms END) AS rn_idx
    FROM comp c
    GROUP BY c.scenario, c.num_products, c.rows_per_prod,
             c.result_rows, c.sel_pct
)
SELECT
    scenario                            AS "シナリオ",
    COALESCE(num_products::TEXT, '?')   AS "商品数",
    result_rows                         AS "返却行数",
    sel_pct                             AS "返却率(%)",
    ROUND(do_noidx, 0)                  AS "DO idx無(ms)",
    ROUND(do_idx,   0)                  AS "DO idx有(ms)",
    ROUND(rn_noidx, 0)                  AS "RN idx無(ms)",
    ROUND(rn_idx,   0)                  AS "RN idx有(ms)",
    CASE
        WHEN do_idx < do_noidx * 0.8 AND do_idx < rn_idx * 0.8
            THEN 'IDX+DO が最速'
        WHEN do_noidx <= rn_noidx * 1.1 AND do_noidx < do_idx * 0.8
            THEN 'NO-IDX+DO が最速'
        WHEN rn_noidx < do_noidx * 0.8 AND rn_noidx < rn_idx * 0.8
            THEN 'NO-IDX+RN が最速'
        WHEN rn_idx < rn_noidx * 0.8 AND rn_idx < do_idx * 0.8
            THEN 'IDX+RN が最速'
        ELSE 'ほぼ同等'
    END                                 AS "判定"
FROM idx_comp
ORDER BY scenario, result_rows;
