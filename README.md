# DB Dev Environment

このプロジェクトは、PostgreSQL と ClickHouse を使用したデータベース開発環境を構築し、データの生成、ロード、クエリを行うためのサンプルです。

## プロジェクト構成

```
.
├── README.md                          # プロジェクトの説明
├── requirements.txt                  # Python 依存パッケージ
├── .devcontainer/                    # Dev Container 関連設定
│   ├── devcontainer.json             # VSCode Dev Container 設定ファイル
│   ├── docker-compose.yml            # PostgreSQL, ClickHouse のサービス定義
│   ├── Dockerfile                    # 開発用イメージのビルド設定
│   └── fs/                           # DB 初期化スクリプト・設定
│       └── volumes/
│           ├── clickhouse/
│           │   ├── docker-entrypoint-initdb.d/
│           │   │   └── 1_create_hacker_news.sh    # ClickHouse の初期化スクリプト
│           │   └── etc/
│           │       └── clickhouse-server/
│           │           ├── config.d/config.xml    # ClickHouse 設定ファイル
│           │           └── users.d/users.xml      # ClickHouse ユーザー設定
│           └── postgres/
│               └── docker-entrypoint-initdb.d/
│                   └── 1_create_and_insert_table_hacker_news.sql  # PostgreSQL 初期化 SQL
├── data/                             # サンプルデータ
│   ├── issues.csv                    # 課題データ（CSV）
│   └── members.csv                   # メンバーデータ（CSV）
└── src/                              # スクリプト類
    ├── generate_issues_csv.py       # サンプルCSV生成スクリプト
    ├── load_init_data.py            # 初期データロードスクリプト
    └── main.py                      # メインの実行エントリーポイント
```

## 使用技術

- **PostgreSQL**: トランザクションデータベース。
- **ClickHouse**: 高速な分析クエリ用のカラムナデータベース。
- **Docker**: 開発環境のコンテナ化。

## セットアップ手順

1. **リポジトリをクローン**
   ```bash
   git clone <リポジトリURL>
   cd db-dev
   ```

2. **Docker コンテナを起動**
    
    VSCode でこのディレクトリを開き、コマンドパレット（`F1` または `Cmd+Shift+P`）で
    `Dev Containers: Reopen in Container` を選択します。
    
    > 起動にはDockerやPodmanなどコンテナ管理ツールのインストールと、VSCodeの設定が必要です。devcontainerのsettingsからDockerPathの値をpodmanに変更してください。[参考](https://qiita.com/akagi_hayato/items/9f74283de75a53ce4ee0)

    > Dev Container 拡張がインストールされていない場合は、インストールを促すダイアログが表示されます。

3. **初期データのロード**
   
   PostgreSQL と ClickHouse に初期データをロードするには、以下のスクリプトを実行します。
   ```bash
   python src/load_init_data.py
   ```

4. **データの生成**
   
   必要に応じて、`generate_issues_csv.py` を使用してデータを生成します。
   ```bash
   python src/generate_issues_csv.py
   ```

## データベース接続情報

- **PostgreSQL**
  - ホスト: `localhost`
  - ポート: `5433`
  - ユーザー: `admin`
  - パスワード: `password`
  - データベース: `clickhouse_pg_db`

- **ClickHouse**
  - ホスト: `localhost`
  - ポート: `8123` (HTTP), `9000` (Native)

## 注意事項

- PostgreSQL の `wal_level=logical` 設定は、ClickHouse の `MaterializedPostgreSQL` 機能を使用するために必要です。
- 初期化スクリプトは `fs/volumes/` 以下に格納されています。

## ライセンス

このプロジェクトは MIT ライセンスの下で提供されています。