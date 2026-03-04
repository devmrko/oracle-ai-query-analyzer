# Case 1: AI 직접 분석 (Tuning Pack 없이 사용)

> **적용 대상**: Oracle Tuning Pack 라이선스가 없거나, SQL Tuning Advisor 없이 AI만으로 분석하는 경우
> **샘플 결과**: [report_001.md](report_001.md)

---

## 1. 개요

Oracle Tuning Pack 라이선스 없이도 사용 가능한 기본 분석 모드입니다.

DB1에서 **실행계획 + 테이블 통계 + 인덱스 정보**를 수집하고, ADB의 AI(LLM)가 이 데이터를 종합 분석하여 성능 최적화 방안을 제시합니다. SQL Tuning Advisor(`DBMS_SQLTUNE`)를 호출하지 않으므로 **Tuning Pack 라이선스가 필요 없습니다.**

```
┌─────────────────────────┐        DB Link        ┌──────────────────────┐
│        DB1 (Primary)     │ ───────────────────── │     ADB              │
│                          │                        │                      │
│  수집 항목:              │   INSERT 요청          │  처리:               │
│  1. EXPLAIN PLAN 실행계획 │ ──────────────────►   │  1. 요청 저장        │
│  2. 테이블 통계 (JSON)   │                        │  2. LLM 프롬프트 구성│
│  3. 인덱스 정보 (JSON)   │   SELECT 결과          │  3. AI 분석 실행     │
│                          │ ◄──────────────────    │  4. 결과 저장        │
│  (Tuning Advisor: 미사용)│                        │                      │
└─────────────────────────┘                        └──────────────────────┘
```

### AI가 분석하는 항목

| 번호 | 분석 항목 | 설명 |
|------|----------|------|
| 1 | 실행계획 요약 | 단계별 실행 흐름, Cost/Rows 해석 |
| 2 | 성능 병목 분석 | Full Table Scan 원인, 비효율적 조인 방식 |
| 3 | 인덱스 활용도 평가 | 미사용 인덱스 식별, 신규 인덱스 DDL 제시 |
| 4 | 최적화된 SQL | 힌트 포함 개선 SQL, 변경 사유 |
| 5 | 추가 권고사항 | 통계 갱신 여부, 파티셔닝/파라미터 제안 |

> **참고:** Tuning Advisor 결과가 없으므로, AI가 실행계획과 통계만으로 분석합니다.
> 그럼에도 인덱스 추천, 힌트 제안, SQL 리팩토링 등 실질적 최적화 방안을 제시합니다.

---

## 2. 사용하는 소스 파일

### DB1 (소스 Oracle DB)에 배포

| 파일 | 용도 | 배포 방법 |
|------|------|----------|
| `src/db1/query_analyzer_pkg.sql` | 핵심 패키지 — 실행계획 추출, 테이블 통계, 인덱스 정보 수집 | SQL*Plus 또는 `test_connection.py` |
| `src/db1/analyze_query_func.sql` | 래퍼 함수 — `analyze_query()` 호출 → 수집 → ADB 전송 → 결과 반환 | SQL*Plus 또는 `test_connection.py` |

### ADB (Oracle Autonomous Database)에 배포

| 파일 | 용도 | 배포 방법 |
|------|------|----------|
| `src/adb/tables.sql` | 요청/결과/로그 테이블 DDL | SQL*Plus |
| `src/adb/ai_profile_setup.sql` | LLM 프로파일 설정 (Grok 4 / OpenAI / OCI 등) | SQL*Plus |
| `src/adb/process_ai_analysis.sql` | AI 분석 프로세서 패키지 — 프롬프트 구성 → LLM 호출 → 결과 저장 | SQL*Plus |
| `src/adb/scheduler_job.sql` | DBMS_SCHEDULER Job — 5초 간격 PENDING 요청 처리, 일일 정리 | SQL*Plus |

### 테스트/유틸리티

| 파일 | 용도 | 실행 시점 |
|------|------|----------|
| `src/db1/test_connection.py` | 패키지/함수 자동 배포 및 기능 테스트 | 최초 배포 시 |
| `src/generate_report.py` | ADB 분석 결과를 Markdown 리포트로 변환 | 결과 확인 시 |

---

## 3. 배포 순서

### Step 1: 환경 설정

`.env` 파일에 접속 정보 설정:

```bash
# DB1 접속 정보
DB1_USER=system
DB1_PASSWORD=<비밀번호>
DB1_DSN=<접속 문자열>

# ADB 접속 정보
ADB_USER=admin
ADB_PASSWORD=<비밀번호>
ADB_DSN=<서비스명>
ADB_WALLET_DIR=<Wallet 경로>
```

### Step 2: ADB 테이블 생성

```bash
# ADB에 접속하여 실행
sqlplus admin/<password>@<adb_service>
@src/adb/tables.sql
```

생성되는 테이블:
- `ai_analysis_request` — 분석 요청 (sql_text, exec_plan, table_stats, index_info, tuning_advice)
- `ai_analysis_result` — LLM 분석 결과
- `ai_analysis_log` — 처리 로그

### Step 3: ADB AI 프로파일 설정

```bash
@src/adb/ai_profile_setup.sql
```

- `<<PLACEHOLDER>>` 값을 실제 환경에 맞게 수정
- OCI / OpenAI / Azure 중 하나를 선택하여 실행

### Step 4: ADB 프로세서 및 스케줄러 배포

```bash
@src/adb/process_ai_analysis.sql
@src/adb/scheduler_job.sql
```

- `ai_query_processor` 패키지: PENDING 요청을 읽어 LLM 호출
- 스케줄러 Job: 5초 간격으로 자동 실행

### Step 5: DB1 패키지/함수 배포

Python 스크립트를 사용하면 배포 + 테스트를 한 번에 수행:

```bash
cd src/db1
python test_connection.py
```

또는 수동 배포:

```sql
-- DB1에 접속하여 실행
@src/db1/query_analyzer_pkg.sql
@src/db1/analyze_query_func.sql
```

### Step 6: DB Link 생성

```sql
-- DB1에서 ADB로의 DB Link 생성
CREATE DATABASE LINK adb_link
    CONNECT TO <adb_user> IDENTIFIED BY <password>
    USING '<adb_tns_alias>';
```

---

## 4. 사용 방법

### 기본 사용

```sql
-- DB1에서 실행
SELECT analyze_query('SELECT * FROM orders WHERE order_date > SYSDATE - 30')
FROM DUAL;
```

### 옵션 지정

```sql
SELECT analyze_query(
    p_sql_text => 'SELECT * FROM orders WHERE status = ''ACTIVE''',
    p_schema   => 'HR',        -- 특정 스키마 지정
    p_timeout  => 120          -- 타임아웃 120초
) FROM DUAL;
```

### 처리 흐름

```
analyze_query() 호출
    │
    ├── 1. query_analyzer.collect_query_info() 호출
    │       ├── EXPLAIN PLAN 실행 → 실행계획 추출
    │       ├── PLAN_TABLE에서 참조 테이블 추출
    │       ├── ALL_TABLES에서 테이블 통계 수집 (JSON)
    │       ├── ALL_INDEXES에서 인덱스 정보 수집 (JSON)
    │       └── Tuning Advisor: 실행 (성공 시 결과 포함, 실패 시 에러 메시지)
    │
    ├── 2. ADB에 INSERT (DB Link)
    │       └── ai_analysis_request 테이블에 저장
    │
    ├── 3. 폴링 대기 (2초 간격)
    │       └── ADB의 스케줄러 Job이 LLM 호출 처리
    │
    └── 4. 결과 SELECT → JSON 반환
```

> **Case 1에서 Tuning Advisor 동작**: `collect_query_info`는 항상 `DBMS_SQLTUNE`을 호출 시도합니다. Tuning Pack 라이선스가 없으면 에러 메시지가 `tuning_advice` 필드에 저장됩니다("SQL Tuning Advisor 실행 실패: ..."). AI 분석에는 영향 없이 나머지 데이터로 분석이 수행됩니다.

### 타임아웃 시 후속 조회

```sql
-- 반환된 request_id로 나중에 결과 조회
SELECT get_analysis_result(123) FROM DUAL;
```

---

## 5. 리포트 생성

분석 결과를 Markdown 리포트로 변환하려면:

```bash
python src/generate_report.py 1 docs/report_001.md
```

- 첫 번째 인자: `request_id`
- 두 번째 인자: 출력 파일 경로

---

## 6. 주요 소스 코드 상세

### `query_analyzer_pkg.sql` — 핵심 패키지

**이 파일이 하는 일:**
1. `EXPLAIN PLAN FOR <SQL>` 실행 → `PLAN_TABLE`에 결과 저장
2. `DBMS_XPLAN.DISPLAY`로 실행계획 텍스트 추출
3. `PLAN_TABLE`에서 참조 테이블명 추출
4. `ALL_TABLES` / `ALL_INDEXES`에서 통계/인덱스 정보를 JSON으로 수집
5. `DBMS_SQLTUNE`으로 Tuning Advisor 실행 (실패 시 에러 메시지 반환)

**주요 함수:**

| 함수 | Case 1에서의 역할 |
|------|------------------|
| `collect_query_info()` | 메인 함수. Primary 경로 실행 (Standby 분기 미사용) |
| `get_execution_plan()` | EXPLAIN PLAN → DBMS_XPLAN.DISPLAY로 실행계획 추출 |
| `get_table_stats()` | 참조 테이블 통계를 JSON 배열로 반환 |
| `get_index_info()` | 참조 테이블 인덱스 정보를 JSON 배열로 반환 |
| `extract_table_names()` | PLAN_TABLE에서 참조 테이블명 추출 |
| `get_tuning_advice()` | DBMS_SQLTUNE 호출 (Tuning Pack 없으면 실패 메시지 반환) |

### `analyze_query_func.sql` — 래퍼 함수

**이 파일이 하는 일:**
1. `collect_query_info()` 호출하여 로컬 데이터 수집
2. DB Link로 ADB의 `ai_analysis_request` 테이블에 INSERT
3. 폴링으로 결과 대기
4. `ai_analysis_result`에서 결과 SELECT → CLOB 반환

### `process_ai_analysis.sql` — ADB AI 프로세서

**이 파일이 하는 일:**
1. `build_prompt()`: SQL + 실행계획 + 통계 + 인덱스 정보 → 구조화된 프롬프트 생성
2. `process_single_request()`: LLM 호출 (재시도 포함) → 결과 저장
3. `process_pending_requests()`: PENDING 요청 배치 처리 (스케줄러에서 호출)

**프롬프트 구조:**
```
당신은 Oracle Database 성능 튜닝 전문가입니다.

## 분석 대상 SQL
(SQL 원문)

## 실행계획 (DBMS_XPLAN)
(실행계획 전문)

## 테이블 통계 (JSON)
(테이블별 num_rows, blocks, avg_row_len 등)

## 인덱스 정보 (JSON)
(인덱스별 컬럼, uniqueness, distinct_keys 등)

## 분석 요청사항
1. 실행계획 요약
2. 성능 병목 분석
3. 인덱스 활용도 평가
4. 최적화된 SQL
5. SQL Tuning Advisor 결과 해석  ← Advisor 결과 없으면 AI가 자체 분석
6. 추가 권고사항
```

---

## 7. 샘플 결과

[report_001.md](report_001.md) 참고. 주요 특징:

- **분석 대상**: 3개 테이블 JOIN (ENM_PROGRAM, ENM_EPISODE, ENM_VOD_DAILY)
- **실행계획**: Cost 8, 전체 Full Table Scan (소규모 데이터)
- **AI 분석 결과**:
  - Full Table Scan 원인 분석 (소규모 데이터로 FTS가 최적)
  - 신규 인덱스 DDL 제시: `CREATE INDEX IDX_VOD_DAILY_DATE_EP ON ENM_VOD_DAILY (VIEW_DATE, EPISODE_ID)`
  - 힌트 포함 최적화 SQL 제시
  - 파티셔닝/Materialized View 등 구조적 개선 제안
- **Tuning Advisor 섹션**: 없음 (Case 1의 특징)

---

## 8. 사전 조건

| 항목 | 요구사항 |
|------|---------|
| DB1 권한 | `CREATE PROCEDURE`, `EXPLAIN ANY`, 대상 테이블 `SELECT` |
| DB1 → ADB | DB Link 생성 (`CREATE DATABASE LINK` 권한) |
| ADB 권한 | `DBMS_CLOUD_AI` 실행, 테이블 생성 |
| LLM 프로파일 | ADB에 AI 프로파일 설정 완료 |
| Oracle 라이선스 | **Tuning Pack 불필요** — Enterprise Edition 기본 기능만 사용 |
