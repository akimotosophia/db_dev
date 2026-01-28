-- クエリコスト比較テストスクリプト
-- マスタテーブルの件数を変えながら、単体SELECT vs JOIN のコストを比較

\pset format unaligned
\pset tuples_only on

-- マスタデータ投入関数
CREATE OR REPLACE FUNCTION insert_master_data(num_records INTEGER)
RETURNS VOID AS $$
BEGIN
    TRUNCATE TABLE product_master;
    INSERT INTO product_master (store_id, product_id, product_name)
    SELECT
        ((i - 1) / 10000) + 1 AS store_id,
        ((i - 1) % 10000) + 1 AS product_id,
        'Product_' || i AS product_name
    FROM generate_series(1, num_records) AS s(i);
END;
$$ LANGUAGE plpgsql;

-- コスト取得関数
CREATE OR REPLACE FUNCTION get_query_cost(query_text TEXT)
RETURNS TABLE(total_cost NUMERIC, startup_cost NUMERIC) AS $$
DECLARE
    plan_json JSONB;
BEGIN
    EXECUTE 'EXPLAIN (FORMAT JSON) ' || query_text INTO plan_json;
    RETURN QUERY SELECT
        (plan_json->0->'Plan'->>'Total Cost')::NUMERIC,
        (plan_json->0->'Plan'->>'Startup Cost')::NUMERIC;
END;
$$ LANGUAGE plpgsql;

-- 結果格納テーブル
DROP TABLE IF EXISTS cost_results;
CREATE TABLE cost_results (
    master_rows INTEGER,
    select_only_cost NUMERIC,
    join_cost NUMERIC,
    cost_ratio NUMERIC,
    test_time TIMESTAMP DEFAULT NOW()
);

-- テストケース配列
DO $$
DECLARE
    master_sizes INTEGER[] := ARRAY[10000, 50000, 100000, 500000, 1000000, 2000000, 5000000, 10000000];
    size INTEGER;
    select_cost NUMERIC;
    join_cost NUMERIC;
BEGIN
    -- 在庫テーブルの統計情報更新
    ANALYZE inventory;

    FOREACH size IN ARRAY master_sizes LOOP
        RAISE NOTICE 'Testing with % master rows...', size;

        -- マスタデータ投入
        PERFORM insert_master_data(size);

        -- 統計情報更新
        ANALYZE product_master;

        -- 単体SELECTのコスト取得
        SELECT total_cost INTO select_cost
        FROM get_query_cost('SELECT * FROM inventory');

        -- JOINのコスト取得
        SELECT total_cost INTO join_cost
        FROM get_query_cost('SELECT i.*, m.product_name FROM inventory i INNER JOIN product_master m ON i.store_id = m.store_id AND i.product_id = m.product_id');

        -- 結果を保存
        INSERT INTO cost_results (master_rows, select_only_cost, join_cost, cost_ratio)
        VALUES (size, select_cost, join_cost, join_cost / select_cost);

        RAISE NOTICE 'Master: % rows, SELECT cost: %, JOIN cost: %, ratio: %',
            size, select_cost, join_cost, ROUND(join_cost / select_cost, 2);
    END LOOP;
END $$;

\pset format aligned
\pset tuples_only off

-- 結果表示
SELECT
    master_rows AS "マスタ件数",
    ROUND(select_only_cost, 2) AS "単体SELECTコスト",
    ROUND(join_cost, 2) AS "JOINコスト",
    ROUND(cost_ratio, 2) AS "倍率(JOIN/SELECT)",
    CASE
        WHEN join_cost <= select_only_cost THEN 'JOIN有利'
        WHEN join_cost <= select_only_cost * 1.5 THEN 'ほぼ同等'
        ELSE 'SELECT有利'
    END AS "判定"
FROM cost_results
ORDER BY master_rows;
