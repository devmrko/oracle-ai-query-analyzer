# Case 3: Standby DB (Read-Only) 환경 적용

> **적용 대상**: DB1이 Standby(읽기 전용) 데이터베이스인 경우
> **핵심**: EXPLAIN PLAN 대신 V$ 메모리 뷰를 사용하여 읽기만으로 분석 수행

---

## 1. 개요

### 왜 별도 경로가 필요한가?

Standby DB(Active Data Guard)는 **읽기 전용**으로 운영됩니다. 기존 Primary 경로에서 사용하는 두 가지 기능이 **쓰기 작업**을 필요로 하기 때문에 Standby에서 동작하지 않습니다:

| 기능 | 필요한 작업 | Standby에서 |
|------|-----------|------------|
| `EXPLAIN PLAN` | `PLAN_TABLE`에 INSERT | **불가** |
| `DBMS_SQLTUNE` | 내부 딕셔너리에 INSERT | **불가** |

### Standby 경로의 대안

| 기능 | Primary (기존) | Standby (대안) |
|------|---------------|---------------|
| 실행계획 추출 | EXPLAIN PLAN → PLAN_TABLE → DBMS_XPLAN.DISPLAY | SQL 실행 → Shared Pool 캐싱 → **DBMS_XPLAN.DISPLAY_CURSOR** |
| 테이블명 추출 | PLAN_TABLE에서 SELECT | **V$SQL_PLAN** 메모리 뷰에서 SELECT |
| 테이블 통계 | ALL_TABLES (동일) | ALL_TABLES (동일) |
| 인덱스 정보 | ALL_INDEXES (동일) | ALL_INDEXES (동일) |
| Tuning Advisor | DBMS_SQLTUNE 실행 | **스킵** (Read-Only에서 불가) |

```
┌──────────────────────────┐       DB Link       ┌──────────────────────┐
│    DB1 (Standby / R-O)    │ ─────────────────── │     ADB              │
│                           │                      │                      │
│  수집 경로:               │   INSERT 요청        │  처리:               │
│  1. SQL 실행 → 캐시 적재  │ ────────────────►   │  1. 요청 저장        │
│  2. V$SQL에서 SQL_ID 검색 │                      │  2. LLM 프롬프트 구성│
│  3. DISPLAY_CURSOR 실행계획│   SELECT 결과        │  3. AI 분석 실행     │
│  4. V$SQL_PLAN 테이블 추출│ ◄────────────────    │  4. 결과 저장        │
│  5. 딕셔너리 뷰 통계/인덱스│                      │                      │
│  6. Tuning Advisor: 스킵  │                      │                      │
│                           │                      │                      │
│  ★ 모두 읽기(SELECT)만   │                      │                      │
└──────────────────────────┘                      └──────────────────────┘
```

---

## 2. 사용하는 소스 파일

Case 1/2와 **완전히 동일한 파일**을 사용합니다. 별도 배포 불필요.

### DB1 배포 파일

| 파일 | Standby에서의 역할 |
|------|------------------|
| `src/db1/query_analyzer_pkg.sql` | `collect_query_info()`에서 자동으로 Standby 경로 선택. Standby 전용 함수 5개 포함 |
| `src/db1/analyze_query_func.sql` | `p_force_standby` / `p_sql_id` 파라미터로 Standby 경로 제어 |

### ADB 배포 파일 (Case 1과 동일)

| 파일 | 역할 |
|------|------|
| `src/adb/tables.sql` | 요청/결과 테이블 (변경 없음) |
| `src/adb/ai_profile_setup.sql` | LLM 프로파일 |
| `src/adb/process_ai_analysis.sql` | AI 프로세서 — Standby 스킵 메시지는 tuning_advice로 전달됨 |
| `src/adb/scheduler_job.sql` | 스케줄러 Job |

### 테스트

| 파일 | 역할 |
|------|------|
| `src/db1/test_standby_mode.py` | **Standby 전용 6단계 테스트** — Primary에서 `p_force_standby=TRUE`로 Standby 경로 검증 |
| `src/db1/test_connection.py` | 배포 테스트 |

---

## 3. 자동 감지 vs 강제 지정

### 자동 감지 (Standby DB에 접속한 경우)

`collect_query_info()`는 내부적으로 `is_standby_db()` 함수를 호출하여 현재 DB의 역할을 자동 판별합니다:

```sql
-- 내부 로직
v_use_standby := NVL(p_force_standby, FALSE) OR is_standby_db();

-- is_standby_db()는 다음을 실행:
-- SELECT database_role FROM v$database → 'PRIMARY'가 아니면 Standby
```

따라서 Standby DB에 접속하여 `analyze_query()`를 호출하면 **자동으로 Standby 경로를 사용**합니다.

### 강제 지정 (Primary에서 Standby 경로 테스트)

Primary DB에서 Standby 경로를 테스트하려면:

```sql
SELECT analyze_query(
    p_sql_text      => 'SELECT * FROM orders WHERE status = ''ACTIVE''',
    p_force_standby => 'Y'
) FROM DUAL;
```

### SQL_ID 직접 지정

V$SQL에서 SQL_ID를 미리 알고 있다면 직접 지정하여 검색 과정을 건너뛸 수 있습니다:

```sql
SELECT analyze_query(
    p_sql_text      => 'SELECT ...',
    p_sql_id        => '5x062n59sxus4',
    p_force_standby => 'Y'
) FROM DUAL;
```

---

## 4. Standby 경로 상세 동작

```
collect_query_info(p_force_standby => TRUE) 또는 Standby DB 접속 시
    │
    ├── 1. SQL_ID 확보
    │       ├── p_sql_id 파라미터가 있으면 → 바로 사용
    │       └── 없으면:
    │             ├── DBMS_SQL.PARSE/EXECUTE → SQL을 Shared Pool에 캐싱
    │             └── find_sql_id() → V$SQL에서 SQL_ID 검색
    │
    ├── 2. SQL_ID가 NULL이면 에러 (V$SQL에서 찾지 못함)
    │
    ├── 3. child_number 조회 (V$SQL에서 MAX)
    │
    ├── 4. DBMS_XPLAN.DISPLAY_CURSOR(sql_id, child_number) → 실행계획 추출
    │
    ├── 5. V$SQL_PLAN에서 참조 테이블명 추출
    │
    ├── 6. ALL_TABLES / ALL_INDEXES에서 통계/인덱스 수집 (Primary와 동일)
    │
    └── 7. Tuning Advisor → 스킵 메시지:
          "[Standby DB] SQL Tuning Advisor는 Read-Only 환경에서 실행할 수 없습니다."
```

---

## 5. Standby 전용 함수 상세

`query_analyzer_pkg.sql`에 포함된 Standby 지원 함수들:

### `is_standby_db() → BOOLEAN`

```sql
-- V$DATABASE.DATABASE_ROLE을 확인하여 Standby 여부 판별
EXECUTE IMMEDIATE 'SELECT database_role FROM v$database' INTO v_role;
RETURN v_role <> 'PRIMARY';
```
- Primary → `FALSE`, PHYSICAL STANDBY 등 → `TRUE`
- V$ 뷰 접근 실패 시 `FALSE` 반환 (안전 기본값)

### `get_db_role() → VARCHAR2`

```sql
-- SQL에서 직접 호출 가능한 버전
SELECT query_analyzer.get_db_role FROM DUAL;
-- 결과: 'PRIMARY' 또는 'PHYSICAL STANDBY' 등
```

### `find_sql_id(p_sql_text) → VARCHAR2`

```sql
-- V$SQL에서 SQL 텍스트 앞 1000자로 매칭하여 가장 최근 SQL_ID 반환
-- 검색 시 자기 자신(v$sql 조회 쿼리)을 제외
```
- SQL을 먼저 실행(`DBMS_SQL`)하여 Shared Pool에 캐싱한 후 검색
- 찾지 못하면 `NULL` 반환

### `get_execution_plan_by_sqlid(p_sql_id, p_child_number) → CLOB`

```sql
-- DBMS_XPLAN.DISPLAY_CURSOR를 사용하여 V$ 뷰에서 실행계획 추출
-- V$ 뷰 읽기만 하므로 Standby에서도 실행 가능
FOR rec IN (
    SELECT plan_table_output
    FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(p_sql_id, v_child, p_plan_format))
) LOOP ...
```

### `extract_table_names_from_cursor(p_sql_id, p_child_number) → t_table_list`

```sql
-- V$SQL_PLAN에서 참조 테이블명 추출 (Standby OK)
-- PLAN_TABLE 대신 V$SQL_PLAN 메모리 뷰 사용
OPEN v_cur FOR 'SELECT DISTINCT object_name FROM v$sql_plan WHERE sql_id = :1 ...'
```

---

## 6. 기술적 이슈: V$ 뷰 접근과 동적 SQL

### 문제

V$ 뷰(`V$DATABASE`, `V$SQL`, `V$SQL_PLAN`)를 PL/SQL 패키지에서 직접 참조하면 컴파일 시 ORA-00942 에러가 발생합니다.

### 원인

Oracle PL/SQL은 컴파일 시점에 **직접 권한(direct grant)**만 확인합니다. SYSTEM 유저는 DBA **역할(role)**을 통해 V$ 뷰 접근 권한이 있지만, 역할 기반 권한은 컴파일 시 인식되지 않습니다.

### 해결

모든 V$ 뷰 접근을 **동적 SQL(`EXECUTE IMMEDIATE`)**로 변경했습니다. 동적 SQL은 실행 시점에 권한을 확인하므로 역할 기반 권한으로도 작동합니다.

```sql
-- 컴파일 에러 (역할 기반 권한 미인식)
SELECT database_role INTO v_role FROM v$database;  -- ORA-00942

-- 해결 (동적 SQL)
EXECUTE IMMEDIATE 'SELECT database_role FROM v$database' INTO v_role;  -- OK
```

---

## 7. 테스트

### 테스트 스크립트 실행

```bash
cd src/db1
python test_standby_mode.py
```

### 6단계 테스트 항목

| 테스트 | 내용 | 검증 포인트 |
|--------|------|------------|
| 1. DB Role 감지 | `get_db_role()` 호출 | PRIMARY 반환 확인 |
| 2. SQL_ID 검색 | SQL 실행 후 `find_sql_id()` | SQL_ID 발견 여부 |
| 3. DISPLAY_CURSOR | `get_execution_plan_by_sqlid()` | 실행계획 추출 성공 |
| 4. V$SQL_PLAN 테이블 | V$SQL_PLAN에서 테이블명 | 테이블명 추출 성공 |
| 5. Standby 전체 플로우 | `collect_query_info(p_force_standby => TRUE)` | 5개 필드 모두 반환 |
| 6. Primary vs Standby 비교 | 동일 SQL로 양쪽 실행 | 통계/인덱스 일치, Tuning 차이 정상 |

### 예상 결과

```
테스트 결과 요약
============================================================
  [OK]   DB Role 감지
  [OK]   SQL_ID 검색
  [OK]   DISPLAY_CURSOR 실행계획
  [OK]   V$SQL_PLAN 테이블명
  [OK]   collect_query_info Standby
  [OK]   Primary vs Standby 비교

모든 테스트 통과!
```

### Primary vs Standby 비교 결과

| 항목 | Primary | Standby | 비고 |
|------|---------|---------|------|
| 실행계획 길이 | ~1,400 bytes | ~1,500 bytes | **형식 차이** (DISPLAY vs DISPLAY_CURSOR) |
| 테이블 통계 | JSON | JSON | **완전 일치** (동일 딕셔너리 뷰) |
| 인덱스 정보 | JSON | JSON | **완전 일치** |
| Tuning Advice | 실제 리포트 | 스킵 메시지 | **의도적 차이** |

---

## 8. 제한 사항

### 8.1 SQL Tuning Advisor 사용 불가

Standby DB에서는 `DBMS_SQLTUNE`을 실행할 수 없습니다. 이것은 Oracle의 기술적 제약으로, 분석 과정에서 내부 딕셔너리에 데이터를 기록(INSERT)해야 하기 때문입니다.

**대안:**
- AI가 실행계획 + 통계만으로도 충분한 최적화 분석을 제공합니다 (Case 1과 동일한 수준)
- Tuning Advisor가 필요하면 Primary DB에서 동일 SQL로 `analyze_query()`를 실행하세요

### 8.2 SQL이 Shared Pool에 있어야 함

`p_sql_id`를 지정하지 않으면, 시스템이 자동으로 SQL을 실행(`DBMS_SQL`)하여 Shared Pool에 캐싱한 후 V$SQL에서 검색합니다.

**검색 실패하는 경우:**
- SQL 실행 자체가 실패하는 경우 (구문 오류 등)
- Shared Pool에서 이미 flush된 경우
- 동일한 SQL이 여러 개여서 정확한 매칭이 안 되는 경우

**해결:** `p_sql_id` 파라미터로 SQL_ID를 직접 지정

```sql
-- SQL_ID를 미리 알아내는 방법
SELECT sql_id, sql_text
FROM v$sql
WHERE sql_text LIKE 'SELECT * FROM orders%'
ORDER BY last_active_time DESC
FETCH FIRST 1 ROWS ONLY;
```

### 8.3 실행계획 출력 형식 차이

- Primary: `DBMS_XPLAN.DISPLAY` — PLAN_TABLE 기반
- Standby: `DBMS_XPLAN.DISPLAY_CURSOR` — V$SQL_PLAN 기반

DISPLAY_CURSOR는 SQL_ID와 SQL 텍스트를 헤더에 포함하므로 출력이 약간 더 깁니다. **실행계획 내용 자체는 동일**합니다.

---

## 9. 사전 조건

| 항목 | 요구사항 |
|------|---------|
| DB1 유형 | Standby (Active Data Guard) 또는 Primary |
| DB1 권한 | `CREATE PROCEDURE`, V$ 뷰 접근 (DBA 역할) |
| V$ 뷰 접근 | `V$DATABASE`, `V$SQL`, `V$SQL_PLAN` — 동적 SQL로 접근 |
| DB1 → ADB | DB Link 생성 (Standby에서도 DB Link를 통한 INSERT 가능 여부 확인 필요) |
| ADB 권한 | `DBMS_CLOUD_AI` 실행, 테이블 생성 |
| Oracle 라이선스 | **Tuning Pack 불필요** — 읽기 전용 작업만 수행 |

> **주의:** Standby에서 DB Link를 통한 INSERT가 제한될 수 있습니다.
> 이 경우 Standby에서는 `collect_query_info()`로 데이터만 수집하고,
> Primary나 별도 서버에서 ADB 전송을 처리하는 구조를 고려하세요.
