-- ============================================================
-- ベンチマーク: Recursive CTE (skip scan) vs DISTINCT ON vs ROW_NUMBER
--
-- 設計方針:
--   - RCTE はインデックスなしだと各ステップで SeqScan → O(商品数×全行) で
--     事実上無限ループになるためインデックスありのみ計測
--   - DISTINCT ON / ROW_NUMBER はあり/なし両方計測
-- ============================================================

\timing on

DROP TABLE IF EXISTS rcte_results;
CREATE TABLE rcte_results (
    label         TEXT,
    total_rows    BIGINT,
    num_products  BIGINT,
    method        TEXT,
    has_index     BOOLEAN,
    execution_ms  NUMERIC,
    result_rows   BIGINT,
    buf_hit       BIGINT,
    disk_read     BIGINT,
    tested_at     TIMESTAMPTZ DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION measure2(
    p_label   TEXT,
    p_total   BIGINT, p_prods BIGINT,
    p_method  TEXT,   p_idx   BOOLEAN, p_sql TEXT
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    plan JSONB; e_ms NUMERIC;
    s_hit BIGINT; s_read BIGINT; ret BIGINT;
BEGIN
    PERFORM pg_stat_reset();
    EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || p_sql INTO plan;
    e_ms  := (plan->0->>'Execution Time')::NUMERIC;
    ret   := (plan->0->'Plan'->>'Actual Rows')::BIGINT;
    s_hit := COALESCE((plan->0->'Plan'->'Shared Hit Blocks')::BIGINT, 0);
    s_read:= COALESCE((plan->0->'Plan'->'Shared Read Blocks')::BIGINT, 0);
    INSERT INTO rcte_results
      (label, total_rows, num_products, method, has_index,
       execution_ms, result_rows, buf_hit, disk_read)
    VALUES
      (p_label, p_total, p_prods, p_method, p_idx,
       e_ms, ret, s_hit, s_read);
    RAISE NOTICE '    % / IDX=% → %ms (返却%件)',
        p_method, p_idx, ROUND(e_ms), ret;
END;
$$;

-- ============================================================
-- シナリオ A: 全件取得 (3サイズ)
-- ============================================================
DO $$
DECLARE
    cfg      RECORD;
    sql_do   TEXT;
    sql_rn   TEXT;
    sql_rc   TEXT;   -- RCTE はインデックスありのみ
BEGIN
    FOR cfg IN
        SELECT total, prods
        FROM (VALUES
            (1000000::BIGINT,  100000::BIGINT),
            (3000000::BIGINT,  100000::BIGINT),
            (3000000::BIGINT, 1000000::BIGINT)
        ) v(total, prods)
    LOOP
        RAISE NOTICE '--- A: %行 / %商品 (%行/商品) ---',
            cfg.total, cfg.prods, cfg.total/cfg.prods;

        PERFORM gen_data(cfg.total, cfg.prods);
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

        -- インデックスなし (RCTE は除外)
        PERFORM measure2('A全件', cfg.total, cfg.prods, 'DISTINCT_ON', false, sql_do);
        PERFORM measure2('A全件', cfg.total, cfg.prods, 'ROW_NUMBER',  false, sql_rn);

        -- インデックスあり (3手法すべて)
        CREATE INDEX tmp_idx ON product_prices (product_id, effective_date DESC);
        PERFORM measure2('A全件', cfg.total, cfg.prods, 'DISTINCT_ON', true, sql_do);
        PERFORM measure2('A全件', cfg.total, cfg.prods, 'ROW_NUMBER',  true, sql_rn);
        PERFORM measure2('A全件', cfg.total, cfg.prods, 'RCTE',        true, sql_rc);
        DROP INDEX tmp_idx;
    END LOOP;
END $$;

-- ============================================================
-- シナリオ B: WHERE 絞り込み (3M / 100K商品)
-- ============================================================
DO $$
DECLARE
    total  BIGINT := 3000000;
    prods  BIGINT := 100000;
    n      BIGINT;
    sql_do TEXT; sql_rn TEXT; sql_rc TEXT;
BEGIN
    RAISE NOTICE '--- B: WHERE 絞り込み (%行 / %商品) ---', total, prods;
    PERFORM gen_data(total, prods);
    ANALYZE product_prices;

    FOREACH n IN ARRAY ARRAY[1, 100, 1000, 10000]::BIGINT[] LOOP
        RAISE NOTICE '  絞り込み %商品', n;

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
                FROM product_prices WHERE product_id <= %s
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

        PERFORM measure2('B絞込', total, prods, 'DISTINCT_ON', false, sql_do);
        PERFORM measure2('B絞込', total, prods, 'ROW_NUMBER',  false, sql_rn);

        CREATE INDEX tmp_idx ON product_prices (product_id, effective_date DESC);
        PERFORM measure2('B絞込', total, prods, 'DISTINCT_ON', true, sql_do);
        PERFORM measure2('B絞込', total, prods, 'ROW_NUMBER',  true, sql_rn);
        PERFORM measure2('B絞込', total, prods, 'RCTE',        true, sql_rc);
        DROP INDEX tmp_idx;
    END LOOP;
END $$;

-- ============================================================
-- 結果表示
-- ============================================================
\pset format aligned

\echo ''
\echo '=== シナリオ A: 全件取得 ==='
SELECT
    total_rows                                             AS "総行数",
    num_products                                           AS "商品数",
    total_rows / num_products                              AS "行/商品",
    method                                                 AS "手法",
    CASE has_index WHEN true THEN 'あり' ELSE 'なし' END  AS "IDX",
    ROUND(execution_ms, 0)                                 AS "実行(ms)",
    disk_read                                              AS "disk_read"
FROM rcte_results
WHERE label = 'A全件'
ORDER BY total_rows, num_products, has_index, method;

\echo ''
\echo '=== シナリオ B: WHERE 絞り込み (3M行/100K商品) ==='
SELECT
    result_rows                                            AS "返却件数",
    method                                                 AS "手法",
    CASE has_index WHEN true THEN 'あり' ELSE 'なし' END  AS "IDX",
    ROUND(execution_ms, 0)                                 AS "実行(ms)",
    disk_read                                              AS "disk_read"
FROM rcte_results
WHERE label = 'B絞込'
ORDER BY result_rows, has_index, method;

\echo ''
\echo '=== 各条件の最速手法 ==='
SELECT
    label || ' / ' ||
    total_rows || '行/' || num_products || '商品' ||
    CASE WHEN r.result_rows < num_products THEN ' 返却' || r.result_rows || '件' ELSE '' END
                                                           AS "条件",
    method                                                 AS "手法",
    CASE has_index WHEN true THEN 'IDX有' ELSE 'IDX無' END AS "インデックス",
    ROUND(execution_ms, 0)                                 AS "実行(ms)",
    RANK() OVER (
        PARTITION BY label, total_rows, num_products, result_rows
        ORDER BY execution_ms
    )                                                      AS "順位"
FROM rcte_results r
ORDER BY label, total_rows, num_products, result_rows, execution_ms;
