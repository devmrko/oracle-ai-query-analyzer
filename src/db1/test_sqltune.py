"""DBMS_SQLTUNE 권한 확인 및 테스트"""
import oracledb
import os
from dotenv import load_dotenv
from pathlib import Path

load_dotenv(Path(__file__).resolve().parent.parent.parent / '.env')
oracledb.init_oracle_client(lib_dir='/Users/joungminko/devkit/instantclient')

db1 = oracledb.connect(
    user=os.getenv('DB1_USER'),
    password=os.getenv('DB1_PASSWORD'),
    dsn=os.getenv('DB1_DSN')
)
cur = db1.cursor()

# 1) 권한 확인
cur.execute(
    "SELECT privilege FROM session_privs "
    "WHERE privilege LIKE '%ADVISOR%' OR privilege LIKE '%TUNING%' "
    "ORDER BY privilege"
)
rows = cur.fetchall()
print('=== 튜닝 관련 권한 ===')
for r in rows:
    print(f'  {r[0]}')

cur.execute(
    "SELECT COUNT(*) FROM all_objects "
    "WHERE object_name = 'DBMS_SQLTUNE' AND object_type = 'PACKAGE'"
)
print(f'\nDBMS_SQLTUNE 존재: {cur.fetchone()[0] > 0}')

# 2) 테스트 실행
print('\n=== SQL Tuning Advisor 테스트 ===')
try:
    v_task = cur.var(oracledb.DB_TYPE_VARCHAR)
    cur.execute("""
        BEGIN
            :task := DBMS_SQLTUNE.CREATE_TUNING_TASK(
                sql_text   => 'SELECT p.program_title, SUM(v.views) AS total_views '
                           || 'FROM ENM_PROGRAM p '
                           || 'JOIN ENM_EPISODE e ON p.program_id = e.program_id '
                           || 'JOIN ENM_VOD_DAILY v ON e.episode_id = v.episode_id '
                           || 'WHERE v.view_date >= DATE ''2025-01-01'' '
                           || 'GROUP BY p.program_title '
                           || 'ORDER BY total_views DESC',
                time_limit => 30,
                task_name  => 'QA_TEST_' || TO_CHAR(SYSTIMESTAMP, 'HH24MISSFF2')
            );
        END;
    """, task=v_task)
    task_name = v_task.getvalue()
    print(f'Task 생성: {task_name}')

    cur.execute("BEGIN DBMS_SQLTUNE.EXECUTE_TUNING_TASK(:1); END;", [task_name])
    print('Task 실행 완료')

    v_report = cur.var(oracledb.DB_TYPE_CLOB)
    cur.execute(
        "BEGIN :report := DBMS_SQLTUNE.REPORT_TUNING_TASK(:task); END;",
        report=v_report,
        task=task_name
    )
    report = v_report.getvalue()
    txt = report.read() if hasattr(report, 'read') else str(report)
    print(f'리포트 길이: {len(txt)} bytes\n')
    print('=' * 70)
    print(txt)
    print('=' * 70)

    # 정리
    cur.execute("BEGIN DBMS_SQLTUNE.DROP_TUNING_TASK(:1); END;", [task_name])
    print('\nTask 정리 완료')

except Exception as e:
    print(f'에러: {e}')

cur.close()
db1.close()
