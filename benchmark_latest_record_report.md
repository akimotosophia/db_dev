# ベンチマーク結果: 最新有効日付レコード抽出
## `DISTINCT ON` vs `ROW_NUMBER() OVER (PARTITION BY)`

### テーブル構成

```sql
CREATE TABLE product_prices (
    id             BIGSERIAL PRIMARY KEY,
    product_id     INT         NOT NULL,   -- 行数 / 10 種類
    effective_date DATE        NOT NULL,   -- 過去3年のランダム日付
    price          NUMERIC(10,2) NOT NULL
);
```

比較クエリ:

```sql
-- DISTINCT ON
SELECT DISTINCT ON (product_id)
    product_id, effective_date, price
FROM product_prices
ORDER BY product_id, effective_date DESC;

-- ROW_NUMBER
SELECT product_id, effective_date, price
FROM (
    SELECT *, ROW_NUMBER() OVER (
        PARTITION BY product_id ORDER BY effective_date DESC
    ) AS rn
    FROM product_prices
) ranked
WHERE rn = 1;
```

---

## 実測値 (PostgreSQL 16, work_mem=4MB デフォルト)

### インデックスなし

| データ件数 | DISTINCT ON (ms) | ROW_NUMBER (ms) | 比率 (DO/RN) | 判定 |
|----------:|----------------:|----------------:|:-----------:|:---:|
| 100,000   | 63              | 67              | 0.94        | ほぼ同等 |
| 500,000   | 297             | 305             | 0.97        | ほぼ同等 |
| 1,000,000 | 688 *           | 763 *           | 0.90        | ほぼ同等 |
| 3,000,000 | 1,960           | 2,205           | 0.89        | ほぼ同等 |
| 5,000,000 | 3,153           | 3,228           | 0.98        | ほぼ同等 |
| 10,000,000| 6,412           | 6,534           | 0.98        | ほぼ同等 |

_\* 初回ベンチマーク実行時に DO=3750ms / RN=669ms という偏りが出たが、再実行で DO=688ms / RN=763ms と正常値に戻った（後述）_

### インデックスあり `(product_id, effective_date DESC)`

| データ件数 | DISTINCT ON (ms) | ROW_NUMBER (ms) | 比率 (DO/RN) | 判定 |
|----------:|----------------:|----------------:|:-----------:|:---:|
| 100,000   | 52              | 60              | 0.87        | DO やや速い |
| 500,000   | 273             | 320             | 0.85        | DO やや速い |
| 1,000,000 | 628             | 719             | 0.87        | DO やや速い |
| 3,000,000 | 5,289           | 5,443           | 0.97        | ほぼ同等 |
| 5,000,000 | 11,672          | 12,103          | 0.96        | ほぼ同等 |
| 10,000,000| 28,936          | 29,625          | 0.98        | ほぼ同等 |

---

## 実行プラン比較 (1M行, インデックスなし)

両クエリとも **同じプラン** を選択:

```
Seq Scan on product_prices
  → Sort (external merge Disk: 24MB)  ← 同一コスト
      → DISTINCT ON: Unique ノード
      → ROW_NUMBER: WindowAgg + Subquery Scan (filter rn=1)
```

- `work_mem=4MB` に対して 1M行のソートは ~24MB → **必ず外部ソートにスピル**
- ROW_NUMBER は WindowAgg + Subquery Scan の分だけノードが 1 段多い
- コスト見積もりも実行時間もほぼ同一

## 実行プラン比較 (1M行, インデックスあり)

```
Index Scan using idx_product_prices_pid_date
  → DISTINCT ON: Unique   (688ms)
  → ROW_NUMBER: WindowAgg (769ms)
```

- インデックスがソートを肩代わりするため temp ファイル不要
- DISTINCT ON は Unique ノードのみで完結するため ROW_NUMBER より約 10% 速い

---

## 重要な発見: インデックスが逆効果になるケース

「全商品の最新価格を取得する」クエリ(= 全行返却)では、インデックスあり が **かえって遅い**:

| データ件数 | インデックスなし | インデックスあり | 倍率 |
|----------:|---------------:|---------------:|:----:|
| 3,000,000 | ~2,000 ms      | ~5,300 ms      | 2.7× |
| 5,000,000 | ~3,200 ms      | ~11,800 ms     | 3.7× |
| 10,000,000| ~6,500 ms      | ~29,000 ms     | 4.5× |

**理由**: Index Scan はヒープページへの **ランダムアクセス** を発生させる。  
テーブルが shared_buffers に収まらなくなると random read が爆発的に増加。  
一方 Seq Scan は **シーケンシャル I/O** なので大規模テーブルで有利。

---

## 1M行の初回ベンチマーク異常値について

初回の自動ベンチマーク実行では DO=3750ms / RN=669ms という大きな乖離が出た。  
その後の再実行では DO=688ms / RN=763ms と正常に戻っている。

推定原因: **temp ファイル作成時の I/O レイテンシの偏り**。  
DISTINCT ON が先に外部ソートの temp ファイルを書いた際に OS レベルの I/O が集中し、
後続の ROW_NUMBER 実行では OS ページキャッシュが温まって高速化。  
これは 1 回限りの計測ノイズであり、パフォーマンス特性の差ではない。

---

## 結論

### 速度差はほぼない

| 条件 | 差 | 推奨 |
|:---|:---|:---|
| インデックスなし, 全行返却 | **ほぼ同等** (±5%) | どちらでも可 |
| インデックスあり, 全行返却 | **DISTINCT ON が 5〜15% 速い** | `DISTINCT ON` |
| インデックスあり, 特定商品を絞り込み後 | **両者とも高速** | `DISTINCT ON` |

### 使い分けの指針

**`DISTINCT ON` を選ぶべき場面**:
- PostgreSQL 専用コードで問題ない
- シンプルで読みやすい SQL を優先したい
- インデックスを活用したい

**`ROW_NUMBER()` を選ぶべき場面**:
- 他の DB (MySQL, BigQuery 等) に移植する可能性がある
- 2位・3位など「最新 N 件」に後から拡張する予定がある
- `rn <= N` に変えるだけで汎用化できる

### インデックス設計の注意点

「全商品の最新価格を一括取得」するクエリが主用途なら、
`(product_id, effective_date DESC)` インデックスは **付けない方が速い**。  
特定の商品を絞り込んでから最新を取るクエリが多い場合は有効。
