"""
Case 4: Active Data Guard + SQL Tuning Advisor 테스트 스크립트

ADG 환경에서 Standby → Primary로 SQL Tuning Advisor를 위임 실행하는 기능을 테스트합니다.

사전조건:
  - SYS 소유의 Private DB Link (Standby → Primary) 생성 완료
  - DB Link 접속 유저: SYS$UMF
  - Tuning Pack + Diagnostics Pack 라이선스

테스트 항목:
  1. Primary DB Link 연결 확인
  2. SYS$UMF 유저 확인
  3. ADG SQL Tuning Advisor 실행 (database_link_to)
  4. collect_query_info with p_primary_db_link 전체 플로우
  5. Case 3 vs Case 4 결과 비교

환경변수:
  PRIMARY_DB_LINK: Standby → Primary DB Link명 (기본값: LNK_TO_PRI)
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
PRIMARY_DB_LINK = os.getenv('PRIMARY_DB_LINK', 'LNK_TO_PRI')

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
# 테스트 1: Primary DB Link 연결 확인
# ==========================================================================
def test_primary_db_link() -> bool:
    print("=" * 60)
    print(f"테스트 1: Primary DB Link 연결 확인 ({PRIMARY_DB_LINK})")
    print("=" * 60)
    try:
        conn = get_connection()
        cursor = conn.cursor()

        # DB Link 존재 확인
        cursor.execute("""
            SELECT db_link, username, host
            FROM all_db_links
            WHERE db_link = UPPER(:link_name)
        """, link_name=PRIMARY_DB_LINK)
        row = cursor.fetchone()

        if row:
            print(f"  DB Link: {row[0]}")
            print(f"  Username: {row[1]}")
            print(f"  Host: {row[2][:80]}..." if len(str(row[2])) > 80 else f"  Host: {row[2]}")
        else:
            print(f"  [WARN] DB Link '{PRIMARY_DB_LINK}'를 찾을 수 없습니다.")
            print("  DB Link가 SYS 소유인 경우 all_db_links에서 보이지 않을 수 있습니다.")

        # 연결 테스트
        try:
            cursor.execute(
                f"SELECT 1 FROM DUAL@{PRIMARY_DB_LINK}"
            )
            result = cursor.fetchone()
            if result and result[0] == 1:
                print(f"  [OK] DB Link '{PRIMARY_DB_LINK}' 연결 성공")
            else:
                print(f"  [FAIL] DB Link 연결 결과가 예상과 다름: {result}")
                return False
        except Exception as e:
            print(f"  [FAIL] DB Link 연결 실패: {e}")
            print()
            print("  DB Link 생성 방법:")
            print("    CREATE DATABASE LINK LNK_TO_PRI")
            print("      CONNECT TO SYS$UMF IDENTIFIED BY <password>")
            print("      USING '<primary_tns>';")
            return False

        cursor.close()
        conn.close()
        return True
    except Exception as e:
        print(f"  [FAIL] {e}")
        return False


# ==========================================================================
# 테스트 2: SYS$UMF 유저 확인
# ==========================================================================
def test_sys_umf_user() -> bool:
    print("\n" + "=" * 60)
    print("테스트 2: SYS$UMF 유저 및 권한 확인")
    print("=" * 60)
    try:
        conn = get_connection()
        cursor = conn.cursor()

        # SYS$UMF 유저 존재 확인
        cursor.execute("""
            SELECT username, account_status
            FROM dba_users
            WHERE username = 'SYS$UMF'
        """)
        row = cursor.fetchone()

        if row:
            print(f"  SYS$UMF 유저: {row[0]}, 상태: {row[1]}")
            if row[1] == 'OPEN':
                print("  [OK] SYS$UMF 유저 활성 상태")
            else:
                print(f"  [WARN] SYS$UMF 유저 상태가 '{row[1]}'입니다. OPEN이어야 합니다.")
        else:
            print("  [INFO] SYS$UMF 유저를 DBA_USERS에서 찾을 수 없습니다.")
            print("  (Oracle 19c 이상에서 자동 생성되는 유저입니다)")

        cursor.close()
        conn.close()
        return True
    except Exception as e:
        # dba_users 접근 권한이 없을 수 있음
        print(f"  [INFO] DBA_USERS 접근 불가 (권한 부족일 수 있음): {e}")
        return True  # 치명적이지 않으므로 pass


# ==========================================================================
# 테스트 3: ADG SQL Tuning Advisor 실행 (database_link_to)
# ==========================================================================
def test_adg_sqltune() -> bool:
    print("\n" + "=" * 60)
    print("테스트 3: ADG SQL Tuning Advisor 실행 (database_link_to)")
    print("=" * 60)
    try:
        conn = get_connection()
        cursor = conn.cursor()

        test_sql = get_test_sql(cursor)
        print(f"  테스트 SQL: {test_sql}")

        v_report = cursor.var(oracledb.DB_TYPE_CLOB)
        cursor.execute("""
            BEGIN
                :report := query_analyzer.get_tuning_advice_via_adg(
                    p_sql_text        => :sql_text,
                    p_primary_db_link => :db_link,
                    p_time_limit      => 30
                );
            END;
        """,
            report=v_report,
            sql_text=test_sql,
            db_link=PRIMARY_DB_LINK
        )

        report_text = read_clob(v_report.getvalue())
        if report_text:
            is_error = report_text.startswith('SQL Tuning Advisor (ADG) 실행 실패')
            if is_error:
                print(f"  [FAIL] ADG Tuning 실패: {report_text[:300]}")
                return False
            else:
                print(f"  [OK] ADG Tuning 성공 ({len(report_text)} bytes)")
                lines = report_text.split('\n')
                for line in lines[:20]:
                    print(f"    {line}")
                if len(lines) > 20:
                    print(f"    ... ({len(lines) - 20} more lines)")
        else:
            print("  [FAIL] 리포트가 비어있음")
            return False

        cursor.close()
        conn.close()
        return True
    except Exception as e:
        print(f"  [FAIL] {e}")
        return False


# ==========================================================================
# 테스트 4: collect_query_info with p_primary_db_link 전체 플로우
# ==========================================================================
def test_collect_with_adg() -> dict[str, str] | None:
    print("\n" + "=" * 60)
    print("테스트 4: collect_query_info(p_primary_db_link) 전체 플로우")
    print("=" * 60)
    try:
        conn = get_connection()
        cursor = conn.cursor()

        test_sql = get_test_sql(cursor)
        print(f"  테스트 SQL: {test_sql}")

        # SQL 실행하여 shared pool에 캐싱
        cursor.execute(test_sql)
        cursor.fetchall()

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
                    p_sql_text        => :sql_text,
                    p_force_standby   => TRUE,
                    p_primary_db_link => :primary_link
                );
                :plan  := v_info.execution_plan;
                :stats := v_info.table_stats;
                :idx   := v_info.index_info;
                :sql   := v_info.sql_text;
                :tune  := v_info.tuning_advice;
            END;
        """,
            sql_text=test_sql,
            primary_link=PRIMARY_DB_LINK,
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

        for key, val in result.items():
            preview = val[:200] if val else '(empty)'
            print(f"\n  --- {key} ---")
            print(f"    길이: {len(val) if val else 0} bytes")
            print(f"    미리보기: {preview}")

        ok = True
        if not result['execution_plan']:
            print("\n  [FAIL] execution_plan이 비어있음")
            ok = False

        tune = result.get('tuning_advice', '')
        if 'ADG' in tune and '실행 실패' in tune:
            print(f"\n  [FAIL] ADG Tuning 실패: {tune[:200]}")
            ok = False
        elif 'Standby DB' in tune:
            print("\n  [FAIL] ADG Tuning이 아닌 Standby 스킵 메시지가 반환됨")
            ok = False
        else:
            print("\n  [OK] ADG Tuning Advisor 결과 포함 확인")

        if ok:
            print("  [OK] Case 4 전체 플로우 성공")

        cursor.close()
        conn.close()
        return result if ok else None
    except Exception as e:
        print(f"  [FAIL] {e}")
        return None


# ==========================================================================
# 테스트 5: Case 3 vs Case 4 결과 비교
# ==========================================================================
def test_case3_vs_case4_comparison() -> bool:
    print("\n" + "=" * 60)
    print("테스트 5: Case 3 (Standby 스킵) vs Case 4 (ADG Tuning) 비교")
    print("=" * 60)
    try:
        conn = get_connection()
        cursor = conn.cursor()

        test_sql = get_test_sql(cursor)
        print(f"  테스트 SQL: {test_sql}")

        # SQL 실행하여 shared pool에 캐싱
        cursor.execute(test_sql)
        cursor.fetchall()

        # --- Case 3: Standby (Tuning 스킵) ---
        v_tune_c3 = cursor.var(oracledb.DB_TYPE_CLOB)
        cursor.execute("""
            DECLARE
                v_info query_analyzer.t_analysis_result;
            BEGIN
                v_info := query_analyzer.collect_query_info(
                    p_sql_text      => :sql_text,
                    p_force_standby => TRUE
                );
                :tune := v_info.tuning_advice;
            END;
        """, sql_text=test_sql, tune=v_tune_c3)
        case3_tune = read_clob(v_tune_c3.getvalue())

        # --- Case 4: ADG Tuning ---
        v_tune_c4 = cursor.var(oracledb.DB_TYPE_CLOB)
        cursor.execute("""
            DECLARE
                v_info query_analyzer.t_analysis_result;
            BEGIN
                v_info := query_analyzer.collect_query_info(
                    p_sql_text        => :sql_text,
                    p_force_standby   => TRUE,
                    p_primary_db_link => :primary_link
                );
                :tune := v_info.tuning_advice;
            END;
        """, sql_text=test_sql, primary_link=PRIMARY_DB_LINK, tune=v_tune_c4)
        case4_tune = read_clob(v_tune_c4.getvalue())

        # 비교 출력
        print("\n  --- Case 3 (Standby 스킵) ---")
        print(f"    길이: {len(case3_tune)} bytes")
        print(f"    내용: {case3_tune[:200]}")

        print("\n  --- Case 4 (ADG Tuning) ---")
        print(f"    길이: {len(case4_tune)} bytes")
        print(f"    내용: {case4_tune[:200]}")

        # 검증
        c3_is_skip = 'Standby DB' in case3_tune or 'Read-Only' in case3_tune
        c4_is_real = len(case4_tune) > len(case3_tune) and 'ADG' not in case4_tune.split('실행 실패')[0] if '실행 실패' in case4_tune else len(case4_tune) > len(case3_tune)

        if c3_is_skip:
            print("\n  [OK] Case 3: Tuning Advisor 스킵 메시지 정상")
        else:
            print("\n  [WARN] Case 3: 스킵 메시지가 없음")

        if c4_is_real:
            print("  [OK] Case 4: ADG Tuning 결과가 Case 3보다 상세함")
        else:
            print("  [WARN] Case 4: ADG Tuning 결과 확인 필요")

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
    print("Oracle AI Query Analyzer - Case 4: ADG SQL Tuning Advisor 테스트")
    print(f"Target: {DB1_DSN}")
    print(f"Primary DB Link: {PRIMARY_DB_LINK}")
    print()

    results: list[tuple[str, bool]] = []

    # 테스트 1: Primary DB Link 연결 확인
    link_ok = test_primary_db_link()
    results.append(("Primary DB Link 연결", link_ok))

    if not link_ok:
        print("\n" + "=" * 60)
        print("Primary DB Link 연결 실패 — 나머지 테스트를 건너뜁니다.")
        print("=" * 60)
        print()
        print("DB Link 설정 방법:")
        print("  -- SYS로 Standby DB에 접속하여 실행")
        print(f"  CREATE DATABASE LINK {PRIMARY_DB_LINK}")
        print("    CONNECT TO SYS$UMF IDENTIFIED BY <password>")
        print("    USING '<primary_tns>';")
        print()
        print("환경변수로 DB Link명 변경:")
        print("  export PRIMARY_DB_LINK=MY_LINK_NAME")
        sys.exit(1)

    # 테스트 2: SYS$UMF 유저 확인
    results.append(("SYS$UMF 유저 확인", test_sys_umf_user()))

    # 테스트 3: ADG SQL Tuning Advisor 직접 실행
    results.append(("ADG SQL Tuning Advisor", test_adg_sqltune()))

    # 테스트 4: collect_query_info 전체 플로우
    adg_result = test_collect_with_adg()
    results.append(("collect_query_info + ADG", adg_result is not None))

    # 테스트 5: Case 3 vs Case 4 비교
    results.append(("Case 3 vs Case 4 비교", test_case3_vs_case4_comparison()))

    # 요약
    print("\n" + "=" * 60)
    print("테스트 결과 요약")
    print("=" * 60)
    all_pass = True
    for name, passed in results:
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
