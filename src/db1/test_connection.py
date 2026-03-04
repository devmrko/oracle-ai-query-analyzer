"""
DB1 접속 테스트 및 query_analyzer 패키지 배포/테스트 스크립트
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

# Thick mode 초기화 (Native Network Encryption 지원)
INSTANT_CLIENT_DIR = os.getenv('INSTANT_CLIENT_DIR', '/Users/joungminko/devkit/instantclient')
try:
    oracledb.init_oracle_client(lib_dir=INSTANT_CLIENT_DIR)
except Exception:
    pass  # 이미 초기화된 경우


def get_connection() -> oracledb.Connection:
    """DB1 접속"""
    return oracledb.connect(
        user=DB1_USER,
        password=DB1_PASSWORD,
        dsn=DB1_DSN
    )


def test_connection() -> bool:
    """접속 테스트"""
    print("=" * 60)
    print("1. DB1 접속 테스트")
    print("=" * 60)
    try:
        conn = get_connection()
        cursor = conn.cursor()
        cursor.execute("SELECT banner FROM v$version WHERE ROWNUM = 1")
        version = cursor.fetchone()[0]
        print(f"  [OK] 접속 성공")
        print(f"  DB Version: {version}")

        cursor.execute("SELECT SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') FROM DUAL")
        schema = cursor.fetchone()[0]
        print(f"  Current Schema: {schema}")

        cursor.execute("SELECT SYS_CONTEXT('USERENV', 'DB_NAME') FROM DUAL")
        db_name = cursor.fetchone()[0]
        print(f"  DB Name: {db_name}")

        cursor.close()
        conn.close()
        return True
    except Exception as e:
        print(f"  [FAIL] 접속 실패: {e}")
        return False


def check_prerequisites() -> bool:
    """사전 조건 확인"""
    print("\n" + "=" * 60)
    print("2. 사전 조건 확인")
    print("=" * 60)
    try:
        conn = get_connection()
        cursor = conn.cursor()

        # PLAN_TABLE 존재 확인
        cursor.execute("""
            SELECT COUNT(*) FROM all_tables
            WHERE table_name = 'PLAN_TABLE'
              AND owner = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')
        """)
        plan_table_exists = cursor.fetchone()[0] > 0

        if not plan_table_exists:
            # SYS 소유 PLAN_TABLE 확인
            cursor.execute("""
                SELECT COUNT(*) FROM all_synonyms
                WHERE synonym_name = 'PLAN_TABLE'
            """)
            plan_table_exists = cursor.fetchone()[0] > 0

        print(f"  PLAN_TABLE 존재: {'OK' if plan_table_exists else 'MISSING'}")

        # DBMS_XPLAN 사용 가능 확인
        cursor.execute("""
            SELECT COUNT(*) FROM all_objects
            WHERE object_name = 'DBMS_XPLAN' AND object_type = 'PACKAGE'
        """)
        xplan_exists = cursor.fetchone()[0] > 0
        print(f"  DBMS_XPLAN 사용 가능: {'OK' if xplan_exists else 'MISSING'}")

        # 테스트용 테이블 존재 확인
        cursor.execute("""
            SELECT COUNT(*) FROM all_tables
            WHERE owner = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')
        """)
        table_count = cursor.fetchone()[0]
        print(f"  현재 스키마 테이블 수: {table_count}")

        cursor.close()
        conn.close()
        return plan_table_exists and xplan_exists
    except Exception as e:
        print(f"  [FAIL] 확인 실패: {e}")
        return False


def deploy_package() -> bool:
    """query_analyzer 패키지 배포"""
    print("\n" + "=" * 60)
    print("3. query_analyzer 패키지 배포")
    print("=" * 60)

    pkg_path = Path(__file__).resolve().parent / 'query_analyzer_pkg.sql'
    if not pkg_path.exists():
        print(f"  [FAIL] 파일 없음: {pkg_path}")
        return False

    sql_content = pkg_path.read_text()

    # spec과 body 분리 (CREATE OR REPLACE 기준)
    blocks = []
    current = ""
    for line in sql_content.split('\n'):
        if line.strip() == '/':
            if current.strip():
                blocks.append(current.strip())
            current = ""
        else:
            current += line + '\n'
    if current.strip():
        blocks.append(current.strip())

    try:
        conn = get_connection()
        cursor = conn.cursor()

        for i, block in enumerate(blocks):
            # 주석만 있는 블록 건너뛰기
            clean = '\n'.join(
                l for l in block.split('\n')
                if not l.strip().startswith('--') and not l.strip().startswith('/*')
                   and not l.strip().startswith('*') and l.strip()
            )
            if not clean.strip():
                continue

            block_type = "Spec" if i == 0 else "Body"
            try:
                cursor.execute(block)
                print(f"  [OK] Package {block_type} 생성 성공")
            except Exception as e:
                print(f"  [FAIL] Package {block_type} 생성 실패: {e}")
                return False

        # 컴파일 오류 확인
        cursor.execute("""
            SELECT name, type, line, text
            FROM user_errors
            WHERE name = 'QUERY_ANALYZER'
            ORDER BY type, sequence
        """)
        errors = cursor.fetchall()
        if errors:
            print(f"\n  [WARN] 컴파일 오류 {len(errors)}건:")
            for name, obj_type, line, text in errors:
                print(f"    {obj_type} Line {line}: {text.strip()}")
            return False
        else:
            print(f"  [OK] 컴파일 오류 없음")

        cursor.close()
        conn.close()
        return True
    except Exception as e:
        print(f"  [FAIL] 배포 실패: {e}")
        return False


def deploy_function() -> bool:
    """analyze_query, get_analysis_result 함수 배포"""
    print("\n" + "=" * 60)
    print("4. 래퍼 함수 배포")
    print("=" * 60)

    func_path = Path(__file__).resolve().parent / 'analyze_query_func.sql'
    if not func_path.exists():
        print(f"  [FAIL] 파일 없음: {func_path}")
        return False

    sql_content = func_path.read_text()

    blocks = []
    current = ""
    for line in sql_content.split('\n'):
        if line.strip() == '/':
            if current.strip():
                blocks.append(current.strip())
            current = ""
        else:
            current += line + '\n'
    if current.strip():
        blocks.append(current.strip())

    try:
        conn = get_connection()
        cursor = conn.cursor()

        func_names = ['analyze_query', 'get_analysis_result']
        func_idx = 0

        for block in blocks:
            clean = '\n'.join(
                l for l in block.split('\n')
                if not l.strip().startswith('--') and not l.strip().startswith('/*')
                   and not l.strip().startswith('*') and l.strip()
            )
            if not clean.strip() or 'CREATE OR REPLACE FUNCTION' not in clean.upper():
                continue

            fname = func_names[func_idx] if func_idx < len(func_names) else f"function_{func_idx}"
            try:
                cursor.execute(block)
                print(f"  [OK] {fname} 함수 생성 성공")
                func_idx += 1
            except Exception as e:
                print(f"  [FAIL] {fname} 함수 생성 실패: {e}")
                return False

        # 컴파일 오류 확인
        cursor.execute("""
            SELECT name, line, text
            FROM user_errors
            WHERE name IN ('ANALYZE_QUERY', 'GET_ANALYSIS_RESULT')
            ORDER BY name, sequence
        """)
        errors = cursor.fetchall()
        if errors:
            print(f"\n  [WARN] 컴파일 오류 {len(errors)}건:")
            for name, line, text in errors:
                print(f"    {name} Line {line}: {text.strip()}")
            return False
        else:
            print(f"  [OK] 컴파일 오류 없음")

        cursor.close()
        conn.close()
        return True
    except Exception as e:
        print(f"  [FAIL] 배포 실패: {e}")
        return False


def test_collect_query_info() -> bool:
    """query_analyzer.collect_query_info 테스트"""
    print("\n" + "=" * 60)
    print("5. collect_query_info 기능 테스트")
    print("=" * 60)

    try:
        conn = get_connection()
        cursor = conn.cursor()

        # 테스트용 SQL — 현재 스키마에 있는 아무 테이블로 간단 테스트
        # 먼저 테이블 하나 확인
        cursor.execute("""
            SELECT table_name FROM user_tables
            WHERE ROWNUM = 1
            ORDER BY table_name
        """)
        row = cursor.fetchone()

        if not row:
            print("  [SKIP] 현재 스키마에 테이블이 없어 테스트 건너뜀")
            print("  -> 테스트용 테이블을 생성하고 다시 시도하세요")
            cursor.close()
            conn.close()
            return True

        test_table = row[0]
        test_sql = f"SELECT * FROM {test_table} WHERE ROWNUM <= 10"
        print(f"  테스트 SQL: {test_sql}")

        # get_execution_plan 단독 테스트
        print(f"\n  --- get_execution_plan 테스트 ---")
        v_plan = cursor.var(oracledb.DB_TYPE_CLOB)
        cursor.execute("""
            BEGIN
                :result := query_analyzer.get_execution_plan(:sql_text);
            END;
        """, result=v_plan, sql_text=test_sql)

        plan_text = v_plan.getvalue()
        if plan_text:
            plan_str = plan_text.read() if hasattr(plan_text, 'read') else str(plan_text)
            print(f"  [OK] 실행계획 추출 성공 ({len(plan_str)} bytes)")
            # 실행계획 첫 10줄 미리보기
            lines = plan_str.split('\n')
            for line in lines[:10]:
                print(f"    {line}")
            if len(lines) > 10:
                print(f"    ... ({len(lines) - 10} more lines)")
        else:
            print("  [WARN] 실행계획이 비어있음")

        cursor.close()
        conn.close()
        return True
    except Exception as e:
        print(f"  [FAIL] 테스트 실패: {e}")
        return False


def main():
    print("Oracle AI Query Analyzer - DB1 테스트")
    print("Target: DB1")
    print()

    # Step 1: 접속 테스트
    if not test_connection():
        print("\n접속 실패. .env 파일의 접속 정보를 확인하세요.")
        sys.exit(1)

    # Step 2: 사전 조건 확인
    if not check_prerequisites():
        print("\n사전 조건 미충족. DBA에게 권한 확인을 요청하세요.")
        sys.exit(1)

    # Step 3: 패키지 배포
    if not deploy_package():
        print("\n패키지 배포 실패. 위의 오류를 확인하세요.")
        sys.exit(1)

    # Step 4: 함수 배포
    if not deploy_function():
        print("\n함수 배포 실패. 위의 오류를 확인하세요.")
        sys.exit(1)

    # Step 5: 기능 테스트
    if not test_collect_query_info():
        print("\n기능 테스트 실패.")
        sys.exit(1)

    print("\n" + "=" * 60)
    print("모든 테스트 완료!")
    print("=" * 60)


if __name__ == '__main__':
    main()
