"""ADB에서 분석 결과를 읽어 MD 리포트를 생성"""
import oracledb
import os
import sys
import json
from dotenv import load_dotenv
from pathlib import Path

load_dotenv(Path(__file__).resolve().parent.parent / '.env')
oracledb.init_oracle_client(
    lib_dir='/Users/joungminko/devkit/instantclient',
    config_dir=os.getenv('ADB_WALLET_DIR')
)


def read_clob(val):
    if val is None:
        return ''
    return val.read() if hasattr(val, 'read') else str(val)


def generate_report(request_id: int, output_path: str):
    adb = oracledb.connect(
        user=os.getenv('ADB_USER'),
        password=os.getenv('ADB_PASSWORD'),
        dsn=os.getenv('ADB_DSN'),
        wallet_location=os.getenv('ADB_WALLET_DIR')
    )
    cur = adb.cursor()

    # 요청 데이터
    cur.execute(
        'SELECT sql_text, exec_plan, table_stats, index_info, tuning_advice, '
        'status, source_db, requested_by, created_at '
        'FROM ai_analysis_request WHERE request_id = :1',
        [request_id]
    )
    row = cur.fetchone()
    if not row:
        print(f'request_id {request_id} not found')
        return

    sql_text = read_clob(row[0])
    exec_plan = read_clob(row[1])
    table_stats_raw = read_clob(row[2])
    index_info_raw = read_clob(row[3])
    tuning_advice = read_clob(row[4])
    status = row[5]
    source_db = row[6]
    requested_by = row[7]
    created_at = row[8]

    # 결과 데이터
    cur.execute(
        'SELECT analysis, model_used, elapsed_secs, created_at '
        'FROM ai_analysis_result WHERE request_id = :1',
        [request_id]
    )
    r = cur.fetchone()
    analysis = read_clob(r[0]) if r else '(결과 없음)'
    model_used = r[1] if r else ''
    elapsed_secs = r[2] if r else 0
    result_at = r[3] if r else ''

    # 테이블 통계 → 마크다운
    ts_md = '| 테이블 | 건수 | 블록 | 평균행길이 | 파티션 | 통계수집일 |\n'
    ts_md += '|--------|------|------|-----------|--------|------------|\n'
    try:
        for t in json.loads(table_stats_raw):
            ts_md += (
                f'| {t["table"]} | {t["num_rows"]:,} | {t["blocks"]} | '
                f'{t["avg_row_len"]} | {t["partitioned"]} | {t["last_analyzed"]} |\n'
            )
    except Exception:
        ts_md += f'| (파싱 실패) | | | | | |\n'

    # 인덱스 정보 → 마크다운
    ix_md = '| 인덱스명 | 테이블 | 컬럼 | 유일성 | 상태 | Distinct Keys |\n'
    ix_md += '|----------|--------|------|--------|------|---------------|\n'
    try:
        for i in json.loads(index_info_raw):
            ix_md += (
                f'| {i["index"]} | {i["table"]} | {i["columns"]} | '
                f'{i["uniqueness"]} | {i["status"]} | {i["distinct_keys"]} |\n'
            )
    except Exception:
        ix_md += f'| (파싱 실패) | | | | | |\n'

    # Tuning Advisor 섹션
    if tuning_advice and len(tuning_advice.strip()) > 0:
        tune_section = f'```\n{tuning_advice}\n```'
    else:
        tune_section = '(Tuning Advisor 결과 없음)'

    # MD 조합
    md = f'''# Query Analysis Report #{request_id:03d}

> **Request ID**: {request_id} | **Source DB**: {source_db} | **Requested By**: {requested_by}
> **Status**: {status} | **요청 시각**: {created_at}
> **분석 모델**: {model_used} (xai.grok-4) | **분석 소요**: {elapsed_secs}초 | **결과 시각**: {result_at}

---

## 1. 분석 대상 SQL

```sql
{sql_text}
```

---

## 2. 실행계획 (DBMS_XPLAN)

```
{exec_plan}
```

---

## 3. 테이블 통계

{ts_md}

---

## 4. 인덱스 정보

{ix_md}

---

## 5. Oracle SQL Tuning Advisor 결과

{tune_section}

---

## 6. AI 분석 결과 (Grok 4)

{analysis}
'''

    with open(output_path, 'w') as f:
        f.write(md)

    print(f'[OK] {output_path} 생성 완료 ({len(md):,} bytes)')

    cur.close()
    adb.close()


if __name__ == '__main__':
    rid = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    out = sys.argv[2] if len(sys.argv) > 2 else f'docs/report_{rid:03d}.md'
    generate_report(rid, out)
