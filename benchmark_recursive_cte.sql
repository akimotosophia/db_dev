-- ============================================================
-- ベンチマーク: Recursive CTE (skip scan) vs DISTINCT ON vs ROW_NUMBER
-- ============================================================

\timing on

DROP TABLE IF EXISTS rcte_results;
CREATE TABLE rcte_results (
    total_rows    BIGINT,
    num_products  BIGINT,
    filter_n      BIGINT,
    method        TEXT,
    has_index     BOOLEAN,
    execution_ms  NUMERIC,
    planning_ms   NUMERIC,
    result_rows   BIGINT,
    buf_hit       BIGINT,
    disk_read     BIGINT,
    tested_at     TIMESTAMPTZ DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION measure2(
    p_total   BIGINT, p_prods BIGINT, p_filter BIGINT,
    p_method  TEXT,   p_idx   BOOLEAN, p_sql TEXT
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    plan JSONB; p_ms NUMERIC; e_ms NUMERIC;
    s_hit BIGINT; s_read BIGINT; ret BIGINT;
BEGIN
    PERFORM pg_stat_reset();
    EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || p_sql INTO plan;
    p_ms  := (plan->0->>'Planning Time')::NUMERIC;
    e_ms  := (plan->0->>'Execution Time')::NUMERIC;
    ret   := (plan->0->'Plan'->>'Actual Rows')::BIGINT;
    s_hit := COALESCE((plan->0->'Plan'->'Shared Hit Blocks')::BIGINT, 0);
    s_read:= COALESCE((plan->0->'Plan'->'Shared Read Blocks')::BIGINT, 0);
    INSERT INTO rcte_results
      (total_rows, num_products, filter_n, method, has_index,
       execution_ms, planning_ms, result_rows, buf_hit, disk_read)
    VALUES
      (p_total, p_prods, p_filter, p_method, p_idx,
       e_ms, p_ms, ret, s_hit, s_read);
END;
$$;

-- ============================================================
-- シナリオ A: 全件取得、rows/商品 比率を変える (10M行固定)
-- ============================================================
DO $$
DECLARE
    total  BIGINT := 10000000;
    prods  BIGINT;
    sql_do TEXT; sql_rn TEXT; sql_rc TEXT;
BEGIN
    FOREACH prods IN ARRAY ARRAY[1000000, 100000, 10000]::BIGINT[] LOOP
        RAISE NOTICE '=== A: % 行 / % 商品 (% 行/商品) ===',
            total, prods, total/prods;
        PERFORM gen_data(total, prods);
        ANALYZE product_prices;

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

        -- Recursive CTE: LATERAL で各商品の先頭1行をインデックスから取得
        -- アンカーに LIMIT がある場合は括弧でラップが必要 (PostgreSQL構文要件)
        sql_rc := $Q$
            WITH RECURSIVE skip AS (
                (SELECT product_id, effective_date, price
                 FROM product_prices
                 ORDER BY product_id, effective_date DESC
                 LIMIT 1)
                UNION ALL
                SELECT nxt.product_id, nxt.effective_date, nxt.price
                FROM skip
                CROSS JOIN LATERAL (
                    SELECT p.product_id, p.effective_date, p.price
                    FROM product_prices p
                    WHERE p.product_id > skip.product_id
                    ORDER BY p.product_id, p.effective_date DESC
                    LIMIT 1
                ) nxt
            )
            SELECT * FROM skip
        $Q$;

        -- インデックスなし
        RAISE NOTICE '  IDX なし...';
        PERFORM measure2(total, prods, NULL, 'DISTINCT ON', false, sql_do);
        PERFORM measure2(total, prods, NULL, 'ROW_NUMBER',  false, sql_rn);
        PERFORM measure2(total, prods, NULL, 'RCTE',        false, sql_rc);

        -- インデックスあり
        CREATE INDEX tmp_idx ON product_prices (product_id, effective_date DESC);
        RAISE NOTICE '  IDX あり...';
        PERFORM measure2(total, prods, NULL, 'DISTINCT ON', true, sql_do);
        PERFORM measure2(total, prods, NULL, 'ROW_NUMBER',  true, sql_rn);
        PERFORM measure2(total, prods, NULL, 'RCTE',        true, sql_rc);
        DROP INDEX tmp_idx;
    END LOOP;
END $$;

-- ============================================================
-- シナリオ B: WHERE 絞り込み (10M / 100K 商品)
-- ============================================================
DO $$
DECLARE
    total BIGINT := 10000000;
    prods BIGINT := 100000;
    n     BIGINT;
    sql_do TEXT; sql_rn TEXT; sql_rc TEXT;
BEGIN
    RAISE NOTICE '=== B: WHERE 絞り込み (% 行 / % 商品) ===', total, prods;
    PERFORM gen_data(total, prods);
    ANALYZE product_prices;

    FOREACH n IN ARRAY ARRAY[1, 100, 1000, 10000]::BIGINT[] LOOP
        RAISE NOTICE '  n=%', n;

        sql_do := format($Q$
            SELECT DISTINCT ON (product_id) product_id, effective_date, price
            FROM product_prices
            WHERE product_id <= %s
            ORDER BY product_id, effective_date DESC
        $Q$, n);

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
        $Q$, n);

        sql_rc := format($Q$
            WITH RECURSIVE skip AS (
                (SELECT product_id, effective_date, price
                 FROM product_prices
                 WHERE product_id <= %s
                 ORDER BY product_id, effective_date DESC
                 LIMIT 1)
                UNION ALL
                SELECT nxt.product_id, nxt.effective_date, nxt.price
                FROM skip
                CROSS JOIN LATERAL (
                    SELECT p.product_id, p.effective_date, p.price
                    FROM product_prices p
                    WHERE p.product_id > skip.product_id
                      AND p.product_id <= %s
                    ORDER BY p.product_id, p.effective_date DESC
                    LIMIT 1
                ) nxt
            )
            SELECT * FROM skip
        $Q$, n, n);

        PERFORM measure2(total, prods, n, 'DISTINCT ON', false, sql_do);
        PERFORM measure2(total, prods, n, 'ROW_NUMBER',  false, sql_rn);
        PERFORM measure2(total, prods, n, 'RCTE',        false, sql_rc);

        CREATE INDEX tmp_idx ON product_prices (product_id, effective_date DESC);
        PERFORM measure2(total, prods, n, 'DISTINCT ON', true, sql_do);
        PERFORM measure2(total, prods, n, 'ROW_NUMBER',  true, sql_rn);
        PERFORM measure2(total, prods, n, 'RCTE',        true, sql_rc);
        DROP INDEX tmp_idx;
    END LOOP;
END $$;

-- ============================================================
-- 結果表示
-- ============================================================
\pset format aligned
\pset tuples_only off

\echo ''
\echo '=== シナリオ A: 全件取得 ==='
SELECT
    num_products                                           AS "商品数",
    total_rows / num_products                              AS "行/商品",
    ROUND(result_rows::NUMERIC / total_rows * 100, 1)     AS "返却率%",
    method                                                 AS "手法",
    CASE has_index WHEN true THEN 'あり' ELSE 'なし' END  AS "IDX",
    ROUND(execution_ms, 0)                                 AS "実行(ms)",
    disk_read                                              AS "disk_read"
FROM rcte_results
WHERE filter_n IS NULL
ORDER BY num_products DESC, has_index, method;

\echo ''
\echo '=== シナリオ B: WHERE 絞り込み (10M行 / 100K商品) ==='
SELECT
    filter_n                                               AS "絞り込み商品数",
    result_rows                                            AS "返却行数",
    method                                                 AS "手法",
    CASE has_index WHEN true THEN 'あり' ELSE 'なし' END  AS "IDX",
    ROUND(execution_ms, 0)                                 AS "実行(ms)",
    disk_read                                              AS "disk_read"
FROM rcte_results
WHERE filter_n IS NOT NULL
ORDER BY filter_n, has_index, method;

\echo ''
\echo '=== 総合比較: 各条件の最速手法 ==='
WITH best AS (
    SELECT
        CASE WHEN filter_n IS NULL
             THEN 'A: 全件 / ' || num_products || '商品'
             ELSE 'B: WHERE<=' || filter_n
        END                                                AS cond,
        CASE has_index WHEN true THEN 'IDX有' ELSE 'IDX無' END AS idx_label,
        method,
        ROUND(execution_ms, 0)                             AS ms,
        RANK() OVER (
            PARTITION BY
                CASE WHEN filter_n IS NULL THEN num_products::TEXT
                     ELSE 'W'||filter_n::TEXT END
            ORDER BY execution_ms
        )                                                  AS rnk
    FROM rcte_results
)
SELECT cond AS "条件", idx_label AS "IDX", method AS "手法", ms AS "実行(ms)",
       CASE rnk WHEN 1 THEN '★ 最速' ELSE '' END AS "判定"
FROM best
ORDER BY cond, ms;
