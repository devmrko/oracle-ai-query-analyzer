# Case 3: Standby DB — End-to-End 플로우

> **적용 대상**: Standby DB (Active Data Guard, Read-Only)
> **핵심**: 로컬 쓰기 불가 → EXPLAIN PLAN 대신 V$ 메모리 뷰, DBMS_SQLTUNE 스킵

---

## Standby에서 불가능한 작업

Standby DB는 **읽기 전용**이므로 Primary 경로의 쓰기 작업이 모두 차단됩니다.

| 작업 | 필요한 쓰기 | Standby | 대안 |
|------|-----------|---------|------|
| `EXPLAIN PLAN FOR <SQL>` | PLAN_TABLE에 INSERT | **불가** | DBMS_SQL 실행 → DISPLAY_CURSOR |
| PLAN_TABLE에서 테이블명 추출 | (PLAN_TABLE이 비어있음) | **불가** | V$SQL_PLAN에서 추출 |
| `DBMS_SQLTUNE` | 내부 딕셔너리에 INSERT | **불가** | 스킵 |
| ALL_TABLES / ALL_INDEXES | SELECT (읽기만) | **가능** | 동일 |

---

## 전체 플로우

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│                              DB1 (Standby / Read-Only)                                   │
│                                                                                          │
│  사용자 호출:                                                                             │
│  SELECT analyze_query(                                                                   │
│      p_sql_text      => 'SELECT * FROM orders WHERE status = ''ACTIVE''',                │
│      p_force_standby => 'Y'         -- Primary에서 Standby 경로 테스트 시               │
│      -- 또는 p_sql_id => '5x062n59sxus4'  -- SQL_ID를 미리 알 때                        │
│  ) FROM DUAL;                                                                            │
│                                                                                          │
│  -- 실제 Standby DB에 접속한 경우 p_force_standby 불필요 (자동 감지)                      │
│                                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐                  │
│  │  Step 1. analyze_query() — src/db1/analyze_query_func.sql          │                  │
│  │                                                                     │                  │
│  │  1-1. collect_query_info(p_force_standby => TRUE) 호출              │                  │
│  │       └─ query_analyzer 패키지 (src/db1/query_analyzer_pkg.sql)    │                  │
│  │                                                                     │                  │
│  │  ┌──────────────────────────────────────────────────────────┐       │                  │
│  │  │  Step 1-0. ★ Standby 감지                                │       │                  │
│  │  │                                                          │       │                  │
│  │  │  is_standby_db()                                         │       │                  │
│  │  │    EXECUTE IMMEDIATE                                     │       │                  │
│  │  │      'SELECT database_role FROM v$database'              │       │                  │
│  │  │    → 'PRIMARY' 아니면 Standby                            │       │                  │
│  │  │                                                          │       │                  │
│  │  │  v_use_standby := p_force_standby OR is_standby_db()     │       │                  │
│  │  │    → TRUE이면 Standby 경로 진입                          │       │                  │
│  │  │                                                          │       │                  │
│  │  │  ⚠ V$ 뷰 접근에 동적 SQL(EXECUTE IMMEDIATE) 사용        │       │                  │
│  │  │    PL/SQL 컴파일 시 역할 기반 권한을 인식 못하므로        │       │                  │
│  │  └──────────────────────────────────────────────────────────┘       │                  │
│  │                                                                     │                  │
│  │  ┌──────────────────────────────────────────────────────────┐       │                  │
│  │  │  Step 1-1. ★ SQL_ID 확보 (Primary와 완전히 다른 경로)    │       │                  │
│  │  │                                                          │       │                  │
│  │  │  Case A: p_sql_id 파라미터가 있으면                      │       │                  │
│  │  │    → 바로 사용 (V$SQL 검색 건너뜀)                       │       │                  │
│  │  │                                                          │       │                  │
│  │  │  Case B: p_sql_id가 없으면                               │       │                  │
│  │  │    1) DBMS_SQL.PARSE/EXECUTE로 SQL을 Shared Pool에 캐싱  │       │                  │
│  │  │       ⚠ 실제 SQL을 실행하여 커서를 생성                  │       │                  │
│  │  │       → Shared Pool에 실행계획이 캐싱됨                  │       │                  │
│  │  │                                                          │       │                  │
│  │  │    2) find_sql_id(p_sql_text) — V$SQL에서 검색           │       │                  │
│  │  │       EXECUTE IMMEDIATE                                  │       │                  │
│  │  │         'SELECT sql_id FROM v$sql                        │       │                  │
│  │  │          WHERE sql_text LIKE :1                          │       │                  │
│  │  │          ORDER BY last_active_time DESC                  │       │                  │
│  │  │          FETCH FIRST 1 ROWS ONLY'                        │       │                  │
│  │  │       → SQL_ID 반환 (못 찾으면 에러)                     │       │                  │
│  │  └──────────────────────────────────────────────────────────┘       │                  │
│  │                                                                     │                  │
│  │  ┌──────────────────────────────────────────────────────────┐       │                  │
│  │  │  Step 1-2. ★ 실행계획 추출 (DISPLAY_CURSOR)              │       │                  │
│  │  │                                                          │       │                  │
│  │  │  V$SQL에서 child_number 조회                             │       │                  │
│  │  │    EXECUTE IMMEDIATE                                     │       │                  │
│  │  │      'SELECT MAX(child_number) FROM v$sql                │       │                  │
│  │  │       WHERE sql_id = :1'                                 │       │                  │
│  │  │                                                          │       │                  │
│  │  │  get_execution_plan_by_sqlid(sql_id, child_number)       │       │                  │
│  │  │    DBMS_XPLAN.DISPLAY_CURSOR(sql_id, child_number, 'ALL')│       │                  │
│  │  │    └─ V$SQL_PLAN 메모리 뷰에서 읽기만 수행 (쓰기 없음)  │       │                  │
│  │  │    └─ PLAN_TABLE 대신 V$SQL_PLAN 사용                    │       │                  │
│  │  │                                                          │       │                  │
│  │  │  출력 형식 차이 (vs Primary):                             │       │                  │
│  │  │    - SQL_ID, child number 헤더 포함                      │       │                  │
│  │  │    - SQL 텍스트 포함                                     │       │                  │
│  │  │    - Query Block Name / Object Alias 섹션 추가           │       │                  │
│  │  │    - SELECT STATEMENT의 Rows/Bytes가 비어있음            │       │                  │
│  │  └──────────────────────────────────────────────────────────┘       │                  │
│  │                                                                     │                  │
│  │  ┌──────────────────────────────────────────────────────────┐       │                  │
│  │  │  Step 1-3. ★ 테이블명 추출 (V$SQL_PLAN에서)              │       │                  │
│  │  │                                                          │       │                  │
│  │  │  extract_table_names_from_cursor(sql_id, child_number)   │       │                  │
│  │  │    EXECUTE IMMEDIATE                                     │       │                  │
│  │  │      'SELECT DISTINCT object_name FROM v$sql_plan        │       │                  │
│  │  │       WHERE sql_id = :1                                  │       │                  │
│  │  │         AND object_type LIKE ''TABLE%''                  │       │                  │
│  │  │         AND object_name IS NOT NULL'                     │       │                  │
│  │  │                                                          │       │                  │
│  │  │  ★ Primary는 PLAN_TABLE에서 추출하지만                   │       │                  │
│  │  │    Standby는 V$SQL_PLAN 메모리 뷰에서 추출               │       │                  │
│  │  └──────────────────────────────────────────────────────────┘       │                  │
│  │                                                                     │                  │
│  │  ┌──────────────────────────────────────────────────────────┐       │                  │
│  │  │  Step 1-4. 통계/인덱스 수집 (Primary와 동일)             │       │                  │
│  │  │                                                          │       │                  │
│  │  │  ALL_TABLES  → num_rows, blocks, avg_row_len 등 (JSON)  │       │                  │
│  │  │  ALL_INDEXES → 인덱스명, 컬럼, uniqueness 등 (JSON)     │       │                  │
│  │  │                                                          │       │                  │
│  │  │  ★ 딕셔너리 뷰는 읽기만이므로 Standby에서도 동일 동작   │       │                  │
│  │  └──────────────────────────────────────────────────────────┘       │                  │
│  │                                                                     │                  │
│  │  ┌──────────────────────────────────────────────────────────┐       │                  │
│  │  │  Step 1-5. ★ Tuning Advisor → 스킵                      │       │                  │
│  │  │                                                          │       │                  │
│  │  │  v_result.tuning_advice :=                               │       │                  │
│  │  │    '[Standby DB] SQL Tuning Advisor는 Read-Only          │       │                  │
│  │  │     환경에서 실행할 수 없습니다.                          │       │                  │
│  │  │     Primary DB에서 analyze_query를 실행하면               │       │                  │
│  │  │     튜닝 조언을 받을 수 있습니다.                        │       │                  │
│  │  │     (사용된 SQL_ID: ' || sql_id || ')'                   │       │                  │
│  │  │                                                          │       │                  │
│  │  │  ★ DBMS_SQLTUNE은 내부 딕셔너리에 INSERT 필요            │       │                  │
│  │  │    → Read-Only 환경에서 실행 불가                        │       │                  │
│  │  └──────────────────────────────────────────────────────────┘       │                  │
│  │                                                                     │                  │
│  │  수집 완료: v_info (execution_plan, table_stats, index_info,        │                  │
│  │             sql_text, tuning_advice)                                │                  │
│  │                                                                     │                  │
│  │  ★ 여기까지 모든 작업이 SELECT/읽기만 — Standby에서 안전           │                  │
│  └─────────────────────────────────────────────────────────────────────┘                  │
│                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────┘
        │
        │  Step 2. DB Link를 통해 ADB에 INSERT
        │
        │  EXECUTE IMMEDIATE
        │    'INSERT INTO ai_analysis_request@ADB_LINK
        │     (sql_text, exec_plan, table_stats, index_info, tuning_advice)
        │     VALUES (:1, :2, :3, :4, :5)
        │     RETURNING request_id INTO :6'
        │
        │  ⚠ Standby에서 DB Link INSERT 가능 여부 — 아래 "제약 사항" 참고
        │
        ▼
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│                                    ADB (Autonomous DB)                                   │
│                                                                                          │
│  ★ ADB 쪽 처리는 Case 1/2와 완전히 동일합니다                                            │
│                                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐                  │
│  │  Step 3. 요청 저장 — src/adb/tables.sql                            │                  │
│  │                                                                     │                  │
│  │  ai_analysis_request 테이블에 INSERT                                │                  │
│  │    request_id: 시퀀스 자동 채번                                     │                  │
│  │    status: 'PENDING'                                                │                  │
│  └─────────────────────────────────────────────────────────────────────┘                  │
│                                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐                  │
│  │  Step 4. Scheduler가 감지 — src/adb/scheduler_job.sql              │                  │
│  │                                                                     │                  │
│  │  AI_ANALYSIS_PROCESSOR_JOB (5초 간격)                               │                  │
│  │    └─ process_pending_requests() → process_single_request()         │                  │
│  └─────────────────────────────────────────────────────────────────────┘                  │
│                                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐                  │
│  │  Step 5. 프롬프트 구성 + LLM 호출 — src/adb/process_ai_analysis.sql│                  │
│  │                                                                     │                  │
│  │  5-1. status → 'PROCESSING'                                        │                  │
│  │                                                                     │                  │
│  │  5-2. build_prompt()                                                │                  │
│  │       - 실행계획: DISPLAY_CURSOR 형식 (SQL_ID 헤더 포함)            │                  │
│  │       - 통계/인덱스: Primary와 동일                                 │                  │
│  │       - Tuning Advisor 섹션: 스킵 메시지 포함                       │                  │
│  │         (build_prompt()는 내용이 있으면 그대로 프롬프트에 포함)      │                  │
│  │                                                                     │                  │
│  │  5-3. DBMS_CLOUD_AI.GENERATE()                                      │                  │
│  │       ┌──────────────────────────────────────────┐                  │                  │
│  │       │ DBMS_CLOUD_AI.GENERATE(                  │                  │                  │
│  │       │   prompt       => v_prompt,              │                  │                  │
│  │       │   profile_name => 'QUERY_ANALYZER_GROK4',│  ← AI Profile   │                  │
│  │       │   action       => 'chat'                 │    참조          │                  │
│  │       │ )                                        │                  │                  │
│  │       └──────────────────────────────────────────┘                  │                  │
│  │                                                                     │                  │
│  │  5-4. 결과 저장 + status → 'DONE'                                   │                  │
│  └─────────────────────────────────────────────────────────────────────┘                  │
│                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────┘
        │
        │  Step 6. DB1이 폴링으로 결과 조회
        │
        ▼
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│                              DB1 (Standby / Read-Only)                                   │
│                                                                                          │
│  6-1. 폴링 (2초 간격) — SELECT만 수행, Standby에서 안전                                  │
│       SELECT status FROM ai_analysis_request@ADB_LINK WHERE request_id = :id             │
│                                                                                          │
│  6-2. 결과 조회                                                                          │
│       SELECT analysis FROM ai_analysis_result@ADB_LINK WHERE request_id = :id            │
│                                                                                          │
│  6-3. CLOB 결과 반환 → AI가 Standby 제약을 고려하여 분석                                  │
│       (인덱스/통계 변경은 Primary에서 하라는 권고 포함)                                    │
│                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Case 3 전용 함수 (Standby 경로)

`query_analyzer_pkg.sql`에 포함된 Standby 전용 함수들:

| 함수 | 역할 | V$ 뷰 | 동적 SQL |
|------|------|--------|----------|
| `is_standby_db()` | DB 역할 감지 (PRIMARY vs STANDBY) | V$DATABASE | `EXECUTE IMMEDIATE` |
| `get_db_role()` | SQL에서 호출 가능한 역할 조회 | V$DATABASE | `EXECUTE IMMEDIATE` |
| `find_sql_id(p_sql_text)` | SQL 텍스트로 V$SQL에서 SQL_ID 검색 | V$SQL | `EXECUTE IMMEDIATE` |
| `get_execution_plan_by_sqlid(sql_id, child)` | DISPLAY_CURSOR로 실행계획 추출 | V$SQL_PLAN | `DBMS_XPLAN.DISPLAY_CURSOR` |
| `extract_table_names_from_cursor(sql_id, child)` | V$SQL_PLAN에서 테이블명 추출 | V$SQL_PLAN | `EXECUTE IMMEDIATE` |

> **왜 동적 SQL?** Oracle PL/SQL은 컴파일 시 **직접 권한(direct grant)**만 확인합니다. V$ 뷰 접근 권한이 **역할(role)** 기반이면 컴파일 에러(ORA-00942)가 발생합니다. `EXECUTE IMMEDIATE`로 실행 시점에 권한을 확인하면 역할 기반 권한으로도 동작합니다.

---

## Standby에서 DB Link INSERT 제약

### 가능한 경우

DB Link를 통한 `INSERT INTO table@ADB_LINK`는 **원격 DB(ADB)에서 쓰기**가 발생합니다. Standby 로컬에는 쓰기가 없으므로 **원칙적으로 가능**합니다.

```
Standby (로컬 쓰기 불가)  ──DB Link──►  ADB (원격 쓰기 발생) → OK
```

### 실패할 수 있는 경우

Oracle의 **분산 트랜잭션(2PC)** 메커니즘이 Standby에서 제한될 수 있습니다:

- `COMMIT` 시 Standby 로컬에 트랜잭션 복구 정보를 기록해야 하는 경우
- Oracle 버전이나 설정에 따라 `ORA-16000: database open for read-only access` 에러 발생 가능

### 대안 아키텍처 (DB Link INSERT가 불가능한 경우)

```
방안 A: Primary 경유

  Standby                    Primary                    ADB
  ────────                   ────────                   ────
  collect_query_info()
    → 수집 데이터 반환
         │
         └─ DB Link ─────►  analyze_query() 호출
                             또는 직접 INSERT@ADB_LINK
                               │
                               └─ DB Link ──────►  요청 저장
                                                   LLM 분석
                                                   결과 반환

방안 B: 애플리케이션 서버 경유

  Standby                    App Server (Python 등)     ADB
  ────────                   ─────────────────────      ────
  collect_query_info()
    → 수집 데이터 반환
         │
         └─ oracledb ─────► 데이터 수신
                             │
                             └─ oracledb ──────►  INSERT into
                                                  ai_analysis_request
                                                  LLM 분석
                                                  결과 반환
```

**방안 B 구현 예시** (`generate_report.py`를 참고):

```python
import oracledb

# 1) Standby에서 수집
standby_conn = oracledb.connect(...)
cursor = standby_conn.cursor()
cursor.execute("""
    DECLARE
        v_info query_analyzer.t_analysis_result;
    BEGIN
        v_info := query_analyzer.collect_query_info(
            p_sql_text => :sql_text,
            p_force_standby => TRUE
        );
        :exec_plan := v_info.execution_plan;
        :table_stats := v_info.table_stats;
        :index_info := v_info.index_info;
        :tuning_advice := v_info.tuning_advice;
    END;
""", ...)

# 2) ADB에 직접 INSERT
adb_conn = oracledb.connect(...)
adb_cursor = adb_conn.cursor()
adb_cursor.execute("""
    INSERT INTO ai_analysis_request
    (sql_text, exec_plan, table_stats, index_info, tuning_advice)
    VALUES (:1, :2, :3, :4, :5)
    RETURNING request_id INTO :6
""", ...)
adb_conn.commit()

# 3) 폴링 + 결과 조회
...
```

---

## 사용하는 소스 파일

| 위치 | 파일 | 이 플로우에서의 역할 |
|------|------|-------------------|
| DB1 | `src/db1/query_analyzer_pkg.sql` | Step 1: `collect_query_info()` — **Standby 전용 함수 5개** 포함 |
| DB1 | `src/db1/analyze_query_func.sql` | Step 1~6: `p_force_standby`, `p_sql_id` 파라미터 지원 |
| DB1 | `src/db1/test_standby_mode.py` | **6단계 Standby 경로 검증** 테스트 |
| ADB | `src/adb/tables.sql` | Step 3: 요청/결과/로그 테이블 (Case 1/2와 동일) |
| ADB | `src/adb/ai_profile_setup.sql` | 사전 설정: Credential + AI Profile (Case 1/2와 동일) |
| ADB | `src/adb/process_ai_analysis.sql` | Step 5: LLM 호출 (Case 1/2와 동일) |
| ADB | `src/adb/scheduler_job.sql` | Step 4: Scheduler Job (Case 1/2와 동일) |

---

## AI Profile 연결 구조

Case 1/2와 동일합니다. ADB 쪽은 수집 경로에 무관하게 같은 AI Profile, 같은 Processor를 사용합니다.

```
ai_profile_setup.sql                    process_ai_analysis.sql
─────────────────────                   ─────────────────────────
DBMS_CLOUD_AI.CREATE_PROFILE(           c_ai_profile CONSTANT := 'QUERY_ANALYZER_GROK4';
  profile_name => 'QUERY_ANALYZER_GROK4',                        │
  attributes => '{                      DBMS_CLOUD_AI.GENERATE(  │
    "provider": "oci",                    profile_name => c_ai_profile  ← 참조
    "credential_name": "OCI_AI_CRED",     ...
    "model": "cohere.command-r-plus"    )
  }'
)
```

---

## 3가지 케이스 비교 (DB1 수집 경로)

ADB 쪽 처리는 3가지 케이스 모두 동일합니다. 차이는 **DB1에서의 데이터 수집 방법**뿐입니다.

| 수집 단계 | Case 1 (Primary, 튜닝팩 없음) | Case 2 (Primary, 튜닝팩) | Case 3 (Standby) |
|----------|------------------------------|-------------------------|------------------|
| Standby 감지 | 불필요 | 불필요 | `is_standby_db()` / `p_force_standby` |
| SQL_ID 확보 | 불필요 | 불필요 | `DBMS_SQL` → `find_sql_id()` |
| 실행계획 | `EXPLAIN PLAN` → `DISPLAY` | `EXPLAIN PLAN` → `DISPLAY` | `DISPLAY_CURSOR` (V$SQL_PLAN) |
| 테이블명 추출 | PLAN_TABLE | PLAN_TABLE | **V$SQL_PLAN** |
| 통계/인덱스 | ALL_TABLES / ALL_INDEXES | ALL_TABLES / ALL_INDEXES | ALL_TABLES / ALL_INDEXES |
| Tuning Advisor | 실패/스킵 | **DBMS_SQLTUNE 전체 실행** | **스킵** (Read-Only) |
| DB Link INSERT | 가능 | 가능 | **제약 있을 수 있음** |

---

## 샘플 결과

→ [report_003.md](report_003.md)
