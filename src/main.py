import psycopg
from clickhouse_connect import get_client

# PostgreSQL 接続テスト
pg_conn = psycopg.connect(
    host="postgres",
    dbname="clickhouse_pg_db",
    user="admin",
    password="password",
    port="5432"
)
print("PostgreSQL connected:", pg_conn)

with pg_conn.cursor() as cur:
    cur.execute("""
        SELECT *
        FROM public.hacker_news
    """)
    hacker_news = cur.fetchall()

print(hacker_news[0])

    
# ClickHouse 接続テスト
ch_client = get_client(host='clickhouse', username='pyuser', password='password')

print("ClickHouse connected:", ch_client.query('SELECT version()'))
