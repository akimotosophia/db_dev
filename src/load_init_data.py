import psycopg
import csv
import polars as pl

# CSVファイルを開く
csv_file_path = 'issues.csv'

# InsertするSQL文（冪等性を担保）
insert_sql = """
    INSERT INTO issues (issue_id, title, description, registered_date, reported_by, 
                        assigned_to, status, priority, importance, due_date, 
                        response_detail, closed_date, category, phase, cause, 
                        estimated_hours, actual_hours)
    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
    ON CONFLICT (issue_id) DO NOTHING;  -- 冪等性を担保
"""

# CSVからデータを読み込み
# PolarsでCSVを読み込む
df = pl.read_csv(csv_file_path)

# データフレームからリストを作成
rows_to_insert = df.select([
    'issue_id', 'title', 'description', 'registered_date', 'reported_by',
    'assigned_to', 'status', 'priority', 'importance', 'due_date',
    'response_detail', 'closed_date', 'category', 'phase', 'cause',
    'estimated_hours', 'actual_hours'
]).to_pandas().values.tolist()


with psycopg.connect(
    host="postgres",
    dbname="clickhouse_pg_db",
    user="admin",
    password="password",
    port="5432"
) as conn:
    with conn.cursor() as cur:
        # テーブルを作成（存在しない場合）
        cur.execute("""
            CREATE TABLE IF NOT EXISTS issues (
                issue_id TEXT PRIMARY KEY,
                title TEXT,
                description TEXT,
                registered_date DATE,
                reported_by TEXT,
                assigned_to TEXT,
                status TEXT,
                priority TEXT,
                importance TEXT,
                due_date DATE,
                response_detail TEXT,
                closed_date DATE,
                category TEXT,
                phase TEXT,
                cause TEXT,
                estimated_hours FLOAT,
                actual_hours FLOAT
            );
        """)
        print("テーブルが作成されました。")
        # バルクインサートを実行（execute_valuesを使用）
        cur.executemany(insert_sql, rows_to_insert)

print(f"データのバルクインサートが完了しました！")
