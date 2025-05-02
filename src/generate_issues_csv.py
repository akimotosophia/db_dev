import pandas as pd
import random
from faker import Faker
from datetime import timedelta
from tqdm import tqdm

# 設定
fake = Faker('ja_JP')
NUM_RECORDS = 100_000
ISSUE_FILE = 'issues.csv'
MEMBER_FILE = 'members.csv'

# メンバー情報
members = [
    {'name': '山田太郎', 'role': 'リーダー'},
    {'name': '佐藤花子', 'role': 'サブリーダー'},
    {'name': '鈴木一郎', 'role': '開発者'},
    {'name': '田中二郎', 'role': '開発者'},
    {'name': '高橋三郎', 'role': 'テスト'}
]
member_names = [m['name'] for m in members]

# メンバーCSV出力
pd.DataFrame(members).to_csv(MEMBER_FILE, index=False, encoding='utf-8-sig')

# 各種リスト（日本語）
statuses = ['登録', '対応中', '対応済', '保留', '却下']
priorities = ['高', '中', '低']
importances = ['重大', '中程度', '軽微']
categories = ['技術的課題', '業務課題', 'セキュリティ', '要件定義', 'テスト']
phases = ['要件定義', '設計', '実装', 'テスト', 'リリース後']
causes = ['考慮漏れ', 'オペレーションミス', '仕様不備', '連携ミス', '未知のバグ']

# 課題データ生成
def generate_issue(i):
    registered_date = fake.date_between(start_date='-2y', end_date='today')
    closed_date = registered_date + timedelta(days=random.randint(1, 30)) if random.random() < 0.8 else ''
    return {
        'issue_id': f'ISSUE-{i:06}',
        'title': fake.sentence(nb_words=6),
        'description': fake.paragraph(nb_sentences=3),
        'registered_date': registered_date,
        'reported_by': random.choice(member_names),
        'assigned_to': random.choice(member_names),
        'status': random.choice(statuses),
        'priority': random.choice(priorities),
        'importance': random.choice(importances),
        'due_date': registered_date + timedelta(days=random.randint(1, 15)),
        'response_detail': fake.paragraph(nb_sentences=2),
        'closed_date': closed_date,
        'category': random.choice(categories),
        'phase': random.choice(phases),
        'cause': random.choice(causes),
        'estimated_hours': round(random.uniform(1, 8), 1),
        'actual_hours': round(random.uniform(1, 8), 1)
    }

# 課題CSV出力
print("課題データ生成中...")
data = [generate_issue(i) for i in tqdm(range(1, NUM_RECORDS + 1))]
df = pd.DataFrame(data)
df.to_csv(ISSUE_FILE, index=False, encoding='utf-8-sig')

print(f"完了！ → {ISSUE_FILE}, {MEMBER_FILE}")
