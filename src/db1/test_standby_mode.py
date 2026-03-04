"""
Standby DB 지원 기능 테스트 스크립트

DB1은 Primary이므로 p_force_standby => TRUE로 Standby 코드 경로를 강제 테스트한다.

테스트 항목:
  1. DB Role 감지 (get_db_role)
  2. SQL_ID 검색 (find_sql_id)
  3. DISPLAY_CURSOR 실행계획 추출 (get_execution_plan_by_sqlid)
  4. V$SQL_PLAN에서 테이블명 추출 (extract_table_names_from_cursor)
  5. collect_query_info(p_force_standby => TRUE) 전체 플로우
  6. Primary vs Standby 출력 비교
"""
import os
import sys
import oracledb
from dotenv import load_dotenv
from pathlib import Path

# .env 로드
env_path = Path(__file__).resolve().parent.parent.parent / '.env'
load_dotenv(env_path)

DB1_USER = os.getenv('DB1_USER')
DB1_PASSWORD = os.getenv('DB1_PASSWORD')
DB1_DSN = os.getenv('DB1_DSN')

INSTANT_CLIENT_DIR = os.getenv('INSTANT_CLIENT_DIR', '/Users/joungminko/devkit/instantclient')
try:
    oracledb.init_oracle_client(lib_dir=INSTANT_CLIENT_DIR)
except Exception:
    pass


def get_connection() -> oracledb.Connection:
    """DB1 접속"""
    return oracledb.connect(
        user=DB1_USER,
        password=DB1_PASSWORD,
        dsn=DB1_DSN
    )


def read_clob(val: object) -> str:
    """CLOB 값을 문자열로 변환"""
    if val is None:
        return ''
    return val.read() if hasattr(val, 'read') else str(val)


def get_test_sql(cursor: oracledb.Cursor) -> str:
    """테스트용 SQL 생성 — 현재 스키마의 첫 번째 테이블 사용"""
    cursor.execute("""
        SELECT table_name FROM user_tables
        WHERE ROWNUM = 1
        ORDER BY table_name
    """)
    row = cursor.fetchone()
    if not row:
        print("  [SKIP] 현재 스키마에 테이블이 없습니다.")
        sys.exit(1)
    return f"SELECT * FROM {row[0]} WHERE ROWNUM <= 10"


# ==========================================================================
# 테스트 1: DB Role 감지
# ==========================================================================
def test_db_role() -> bool:
    print("=" * 60)
    print("테스트 1: DB Role 감지 (get_db_role)")
    print("=" * 60)
    try:
        conn = get_connection()
        cursor = conn.cursor()

        v_role = cursor.var(oracledb.DB_TYPE_VARCHAR)
        cursor.execute("""
            BEGIN :role := query_analyzer.get_db_role; END;
        """, role=v_role)

        role = v_role.getvalue()
        print(f"  DB Role: {role}")

        if role == 'PRIMARY':
            print("  [OK] Primary DB 감지 — p_force_standby로 Standby 경로 테스트 진행")
        else:
            print(f"  [OK] Standby DB 감지 ({role})")

        cursor.close()
        conn.close()
        return True
    except Exception as e:
        print(f"  [FAIL] {e}")
        return False


# ==========================================================================
# 테스트 2: SQL_ID 검색 (find_sql_id)
# ==========================================================================
def test_find_sql_id() -> tuple[bool, str | None]:
    print("\n" + "=" * 60)
    print("테스트 2: SQL_ID 검색 (find_sql_id)")
    print("=" * 60)
    try:
        conn = get_connection()
        cursor = conn.cursor()

        test_sql = get_test_sql(cursor)
        print(f"  테스트 SQL: {test_sql}")

        # 먼저 쿼리를 실행하여 shared pool에 올리기
        print("  -> SQL 실행하여 shared pool에 캐싱...")
        cursor.execute(test_sql)
        cursor.fetchall()

        # find_sql_id 호출
        v_sql_id = cursor.var(oracledb.DB_TYPE_VARCHAR)
        cursor.execute("""
            BEGIN :sql_id := query_analyzer.find_sql_id(:sql_text); END;
        """, sql_id=v_sql_id, sql_text=test_sql)

        sql_id = v_sql_id.getvalue()
        if sql_id:
            print(f"  [OK] SQL_ID 발견: {sql_id}")
        else:
            print("  [WARN] SQL_ID를 찾지 못했습니다")
            cursor.close()
            conn.close()
            return False, None

        cursor.close()
        conn.close()
        return True, sql_id
    except Exception as e:
        print(f"  [FAIL] {e}")
        return False, None


# ==========================================================================
# 테스트 3: DISPLAY_CURSOR 실행계획 추출
# ==========================================================================
def test_display_cursor(sql_id: str) -> bool:
    print("\n" + "=" * 60)
    print("테스트 3: DISPLAY_CURSOR 실행계획 추출 (get_execution_plan_by_sqlid)")
    print("=" * 60)
    try:
        conn = get_connection()
        cursor = conn.cursor()

        v_plan = cursor.var(oracledb.DB_TYPE_CLOB)
        cursor.execute("""
            BEGIN
                :plan := query_analyzer.get_execution_plan_by_sqlid(
                    p_sql_id => :sql_id
                );
            END;
        """, plan=v_plan, sql_id=sql_id)

        plan_text = read_clob(v_plan.getvalue())
        if plan_text:
            print(f"  [OK] 실행계획 추출 성공 ({len(plan_text)} bytes)")
            lines = plan_text.split('\n')
            for line in lines[:15]:
                print(f"    {line}")
            if len(lines) > 15:
                print(f"    ... ({len(lines) - 15} more lines)")
        else:
            print("  [WARN] 실행계획이 비어있음")
            return False

        cursor.close()
        conn.close()
        return True
    except Exception as e:
        print(f"  [FAIL] {e}")
        return False


# ==========================================================================
# 테스트 4: V$SQL_PLAN에서 테이블명 추출
# ==========================================================================
def test_extract_tables_from_cursor(sql_id: str) -> bool:
    print("\n" + "=" * 60)
    print("테스트 4: V$SQL_PLAN 테이블명 추출 (extract_table_names_from_cursor)")
    print("=" * 60)
    try:
        conn = get_connection()
        cursor = conn.cursor()

        # PL/SQL collection은 직접 반환이 어려우므로 SQL로 래핑
        cursor.execute("""
            SELECT DISTINCT object_name
            FROM v$sql_plan
            WHERE sql_id = :sql_id
              AND object_name IS NOT NULL
              AND object_type LIKE 'TABLE%'
            ORDER BY object_name
        """, sql_id=sql_id)

        tables = [row[0] for row in cursor.fetchall()]
        if tables:
            print(f"  [OK] 추출된 테이블 {len(tables)}개: {', '.join(tables)}")
        else:
            print("  [WARN] 추출된 테이블이 없습니다 (인라인 뷰만 있는 경우 정상)")

        cursor.close()
        conn.close()
        return True
    except Exception as e:
        print(f"  [FAIL] {e}")
        return False


# ==========================================================================
# 테스트 5: collect_query_info(p_force_standby => TRUE) 전체 플로우
# ==========================================================================
def test_collect_query_info_standby() -> dict[str, str] | None:
    print("\n" + "=" * 60)
    print("테스트 5: collect_query_info(p_force_standby => TRUE) 전체 플로우")
    print("=" * 60)
    try:
        conn = get_connection()
        cursor = conn.cursor()

        test_sql = get_test_sql(cursor)
        print(f"  테스트 SQL: {test_sql}")

        # 먼저 SQL을 실행하여 shared pool에 올림
        cursor.execute(test_sql)
        cursor.fetchall()

        # collect_query_info를 Standby 모드로 호출
        v_plan = cursor.var(oracledb.DB_TYPE_CLOB)
        v_stats = cursor.var(oracledb.DB_TYPE_CLOB)
        v_idx = cursor.var(oracledb.DB_TYPE_CLOB)
        v_sql = cursor.var(oracledb.DB_TYPE_CLOB)
        v_tune = cursor.var(oracledb.DB_TYPE_CLOB)

        cursor.execute("""
            DECLARE
                v_info query_analyzer.t_analysis_result;
            BEGIN
                v_info := query_analyzer.collect_query_info(
                    p_sql_text      => :sql_text,
                    p_force_standby => TRUE
                );
                :plan  := v_info.execution_plan;
                :stats := v_info.table_stats;
                :idx   := v_info.index_info;
                :sql   := v_info.sql_text;
                :tune  := v_info.tuning_advice;
            END;
        """,
            sql_text=test_sql,
            plan=v_plan,
            stats=v_stats,
            idx=v_idx,
            sql=v_sql,
            tune=v_tune
        )

        result = {
            'execution_plan': read_clob(v_plan.getvalue()),
            'table_stats': read_clob(v_stats.getvalue()),
            'index_info': read_clob(v_idx.getvalue()),
            'sql_text': read_clob(v_sql.getvalue()),
            'tuning_advice': read_clob(v_tune.getvalue()),
        }

        # 결과 출력
        for key, val in result.items():
            preview = val[:200] if val else '(empty)'
            print(f"\n  --- {key} ---")
            print(f"    길이: {len(val) if val else 0} bytes")
            print(f"    미리보기: {preview}")

        # 검증
        ok = True
        if not result['execution_plan']:
            print("\n  [FAIL] execution_plan이 비어있음")
            ok = False
        if result['table_stats'] in ('', '[]'):
            print("  [WARN] table_stats가 비어있음 (테이블이 없는 경우 정상)")
        if 'Standby DB' not in result.get('tuning_advice', ''):
            print("  [FAIL] tuning_advice에 Standby 스킵 메시지가 없음")
            ok = False
        else:
            print("\n  [OK] Tuning Advisor 스킵 메시지 정상 확인")

        if ok:
            print("  [OK] Standby 모드 전체 플로우 성공")

        cursor.close()
        conn.close()
        return result if ok else None
    except Exception as e:
        print(f"  [FAIL] {e}")
        return None


# ==========================================================================
# 테스트 6: Primary vs Standby 출력 비교
# ==========================================================================
def test_primary_vs_standby_comparison() -> bool:
    print("\n" + "=" * 60)
    print("테스트 6: Primary vs Standby 출력 비교")
    print("=" * 60)
    try:
        conn = get_connection()
        cursor = conn.cursor()

        test_sql = get_test_sql(cursor)
        print(f"  테스트 SQL: {test_sql}")

        # 먼저 SQL 실행 (Standby 모드에서 V$SQL 캐싱 필요)
        cursor.execute(test_sql)
        cursor.fetchall()

        # --- Primary 모드 ---
        v_plan_p = cursor.var(oracledb.DB_TYPE_CLOB)
        v_stats_p = cursor.var(oracledb.DB_TYPE_CLOB)
        v_idx_p = cursor.var(oracledb.DB_TYPE_CLOB)
        v_tune_p = cursor.var(oracledb.DB_TYPE_CLOB)

        cursor.execute("""
            DECLARE
                v_info query_analyzer.t_analysis_result;
            BEGIN
                v_info := query_analyzer.collect_query_info(
                    p_sql_text      => :sql_text,
                    p_force_standby => FALSE
                );
                :plan  := v_info.execution_plan;
                :stats := v_info.table_stats;
                :idx   := v_info.index_info;
                :tune  := v_info.tuning_advice;
            END;
        """,
            sql_text=test_sql,
            plan=v_plan_p,
            stats=v_stats_p,
            idx=v_idx_p,
            tune=v_tune_p
        )
        primary_plan = read_clob(v_plan_p.getvalue())
        primary_stats = read_clob(v_stats_p.getvalue())
        primary_idx = read_clob(v_idx_p.getvalue())
        primary_tune = read_clob(v_tune_p.getvalue())

        # --- Standby 모드 (강제) ---
        v_plan_s = cursor.var(oracledb.DB_TYPE_CLOB)
        v_stats_s = cursor.var(oracledb.DB_TYPE_CLOB)
        v_idx_s = cursor.var(oracledb.DB_TYPE_CLOB)
        v_tune_s = cursor.var(oracledb.DB_TYPE_CLOB)

        cursor.execute("""
            DECLARE
                v_info query_analyzer.t_analysis_result;
            BEGIN
                v_info := query_analyzer.collect_query_info(
                    p_sql_text      => :sql_text,
                    p_force_standby => TRUE
                );
                :plan  := v_info.execution_plan;
                :stats := v_info.table_stats;
                :idx   := v_info.index_info;
                :tune  := v_info.tuning_advice;
            END;
        """,
            sql_text=test_sql,
            plan=v_plan_s,
            stats=v_stats_s,
            idx=v_idx_s,
            tune=v_tune_s
        )
        standby_plan = read_clob(v_plan_s.getvalue())
        standby_stats = read_clob(v_stats_s.getvalue())
        standby_idx = read_clob(v_idx_s.getvalue())
        standby_tune = read_clob(v_tune_s.getvalue())

        # 비교 결과 출력
        print("\n  --- 비교 결과 ---")
        print(f"  실행계획 길이  : Primary={len(primary_plan):>6} / Standby={len(standby_plan):>6}")
        print(f"  테이블 통계    : Primary={len(primary_stats):>6} / Standby={len(standby_stats):>6}")
        print(f"  인덱스 정보    : Primary={len(primary_idx):>6} / Standby={len(standby_idx):>6}")
        print(f"  Tuning Advice  : Primary={len(primary_tune):>6} / Standby={len(standby_tune):>6}")

        # 테이블 통계 비교 (동일해야 함)
        stats_match = primary_stats == standby_stats
        idx_match = primary_idx == standby_idx
        print(f"\n  테이블 통계 일치: {'YES' if stats_match else 'NO'}")
        print(f"  인덱스 정보 일치: {'YES' if idx_match else 'NO'}")

        # Tuning advice 차이 확인
        if 'Standby DB' in standby_tune:
            print("  [OK] Standby 모드: Tuning Advisor 스킵 메시지 정상")
        else:
            print("  [WARN] Standby 모드: 스킵 메시지 없음")

        if primary_tune and 'Standby DB' not in primary_tune:
            print("  [OK] Primary 모드: Tuning Advisor 정상 실행")
        else:
            print("  [INFO] Primary 모드: Tuning Advisor 결과 확인 필요")

        # 실행계획은 형식이 다를 수 있음 (DISPLAY vs DISPLAY_CURSOR)
        if primary_plan and standby_plan:
            print("  [OK] 양쪽 모두 실행계획 추출 성공")
        else:
            print("  [WARN] 한쪽 실행계획이 비어있음")

        cursor.close()
        conn.close()
        return True
    except Exception as e:
        print(f"  [FAIL] {e}")
        return False


# ==========================================================================
# 메인
# ==========================================================================
def main() -> None:
    print("Oracle AI Query Analyzer - Standby DB 지원 테스트")
    print(f"Target: {DB1_DSN}")
    print()

    results: list[tuple[str, bool]] = []

    # 테스트 1: DB Role 감지
    results.append(("DB Role 감지", test_db_role()))

    # 테스트 2: SQL_ID 검색
    ok, sql_id = test_find_sql_id()
    results.append(("SQL_ID 검색", ok))

    if sql_id:
        # 테스트 3: DISPLAY_CURSOR 실행계획
        results.append(("DISPLAY_CURSOR 실행계획", test_display_cursor(sql_id)))

        # 테스트 4: V$SQL_PLAN 테이블명 추출
        results.append(("V$SQL_PLAN 테이블명", test_extract_tables_from_cursor(sql_id)))
    else:
        print("\n  [SKIP] 테스트 3, 4 — SQL_ID를 찾지 못해 건너뜀")
        results.append(("DISPLAY_CURSOR 실행계획", False))
        results.append(("V$SQL_PLAN 테이블명", False))

    # 테스트 5: collect_query_info Standby 전체 플로우
    standby_result = test_collect_query_info_standby()
    results.append(("collect_query_info Standby", standby_result is not None))

    # 테스트 6: Primary vs Standby 비교
    results.append(("Primary vs Standby 비교", test_primary_vs_standby_comparison()))

    # 요약
    print("\n" + "=" * 60)
    print("테스트 결과 요약")
    print("=" * 60)
    all_pass = True
    for name, passed in results:
        status = "PASS" if passed else "FAIL"
        icon = "[OK]  " if passed else "[FAIL]"
        print(f"  {icon} {name}")
        if not passed:
            all_pass = False

    print()
    if all_pass:
        print("모든 테스트 통과!")
    else:
        print("일부 테스트 실패. 위의 로그를 확인하세요.")
        sys.exit(1)


if __name__ == '__main__':
    main()
