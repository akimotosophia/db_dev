-- クエリコスト比較テスト
-- PostgreSQL 16.4

-- テストデータベース作成
DROP DATABASE IF EXISTS cost_test;
CREATE DATABASE cost_test;
\c cost_test

-- 既存テーブル削除
DROP TABLE IF EXISTS inventory CASCADE;
DROP TABLE IF EXISTS product_master CASCADE;

-- ============================================
-- 在庫テーブル（ハッシュパーティション）
-- 店舗、商品が主キー、在庫数が属性
-- 100ハッシュパーティション、1000万件
-- ============================================
CREATE TABLE inventory (
    store_id INTEGER NOT NULL,
    product_id INTEGER NOT NULL,
    stock_quantity INTEGER NOT NULL,
    PRIMARY KEY (store_id, product_id)
) PARTITION BY HASH (store_id);

-- 100個のハッシュパーティションを作成
DO $$
BEGIN
    FOR i IN 0..99 LOOP
        EXECUTE format(
            'CREATE TABLE inventory_p%s PARTITION OF inventory
             FOR VALUES WITH (MODULUS 100, REMAINDER %s)',
            i, i
        );
    END LOOP;
END $$;

-- ============================================
-- マスタテーブル（パーティションなし）
-- 店舗、商品が主キー、商品名が属性
-- ============================================
CREATE TABLE product_master (
    store_id INTEGER NOT NULL,
    product_id INTEGER NOT NULL,
    product_name VARCHAR(100) NOT NULL,
    PRIMARY KEY (store_id, product_id)
);

-- ============================================
-- テストデータ投入関数
-- ============================================

-- 在庫テーブルに1000万件投入
-- 店舗数: 1000, 商品数: 10000 → 1000万件
INSERT INTO inventory (store_id, product_id, stock_quantity)
SELECT
    s.store_id,
    p.product_id,
    (random() * 1000)::INTEGER AS stock_quantity
FROM
    generate_series(1, 1000) AS s(store_id),
    generate_series(1, 10000) AS p(product_id);

-- マスタテーブルにデータ投入する関数
CREATE OR REPLACE FUNCTION insert_master_data(num_records INTEGER)
RETURNS VOID AS $$
BEGIN
    -- 既存データ削除
    TRUNCATE TABLE product_master;

    -- マスタデータ投入
    INSERT INTO product_master (store_id, product_id, product_name)
    SELECT
        ((i - 1) / 10000) + 1 AS store_id,  -- 店舗ID: 1〜(num_records/10000)
        ((i - 1) % 10000) + 1 AS product_id, -- 商品ID: 1〜10000
        'Product_' || i AS product_name
    FROM generate_series(1, num_records) AS s(i);
END;
$$ LANGUAGE plpgsql;

-- 統計情報更新
ANALYZE inventory;
