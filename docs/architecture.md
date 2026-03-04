# Oracle AI Query Analyzer - 아키텍처 문서

> **최종 수정일**: 2026-03-04

---

## 1. 프로젝트 개요

Oracle DB(이하 DB1)에서 실행되는 SQL 쿼리의 실행계획을 수집하고, DB Link로 연결된 Oracle ADB(Autonomous Database)에서 LLM을 활용하여 쿼리 성능 분석 및 최적화 방안을 자동 제시하는 시스템.

### 목표

- DB1의 SQL 실행계획을 자동 수집 및 분석
- ADB의 AI 기능(DBMS_CLOUD_AI)을 활용한 지능형 쿼리 최적화 제안
- DBA/개발자가 PL/SQL 함수 하나로 간편하게 분석 결과를 받을 수 있도록 함

### 3가지 적용 케이스

| 케이스 | DB1 환경 | 라이선스 | 수집 경로 | Tuning Advisor |
|--------|---------|---------|----------|----------------|
| **Case 1** | Primary | EE 기본 | EXPLAIN PLAN → DISPLAY | 미사용 |
| **Case 2** | Primary | Tuning Pack | EXPLAIN PLAN → DISPLAY | **DBMS_SQLTUNE 실행** |
| **Case 3** | Standby (Read-Only) | EE 기본 | DBMS_SQL → DISPLAY_CURSOR | 스킵 (쓰기 불가) |

→ 케이스별 상세: [Case 1](case1_ai_direct_analysis.md) / [Case 2](case2_with_tuning_pack.md) / [Case 3](case3_standby_db.md)
→ 케이스별 플로우: [Flow 1](flow_case1.md) / [Flow 2](flow_case2.md) / [Flow 3](flow_case3.md)

---

## 2. 시스템 아키텍처

### 전체 흐름

```
┌──────────────────────────────┐       DB Link       ┌──────────────────────────────┐
│       DB1 (Oracle)            │ ─────────────────── │       ADB (Autonomous)        │
│                                │                     │                                │
│  ┌─────────────────────────┐   │   INSERT 요청       │  ┌────────────────────────┐    │
│  │ query_analyzer           │   │ ───────────────►   │  │ ai_analysis_request     │    │
│  │ (PL/SQL Package)         │   │                    │  └──────────┬─────────────┘    │
│  │                           │   │                    │             │                  │
│  │ Primary 경로:             │   │                    │             ▼                  │
│  │ - EXPLAIN PLAN → DISPLAY  │   │                    │  ┌────────────────────────┐    │
│  │ - PLAN_TABLE 테이블명     │   │                    │  │ DBMS_SCHEDULER          │    │
│  │ - [Case2] DBMS_SQLTUNE   │   │                    │  │ (5초 간격 비동기 처리)  │    │
│  │                           │   │                    │  └──────────┬─────────────┘    │
│  │ Standby 경로:             │   │                    │             │                  │
│  │ - DBMS_SQL → DISPLAY_CURSOR│  │                    │             ▼                  │
│  │ - V$SQL_PLAN 테이블명     │   │                    │  ┌────────────────────────┐    │
│  │ - Tuning Advisor 스킵     │   │                    │  │ ai_query_processor      │    │
│  └───────────┬─────────────┘   │                    │  │  build_prompt()          │    │
│              │                  │                    │  │  DBMS_CLOUD_AI.GENERATE  │    │
│              ▼                  │                    │  └──────────┬─────────────┘    │
│  ┌─────────────────────────┐   │   SELECT 결과       │             │                  │
│  │ analyze_query()          │   │ ◄───────────────   │             ▼                  │
│  │ (래퍼 함수)              │   │                    │  ┌────────────────────────┐    │
│  │ - DB Link INSERT         │   │                    │  │ AI Profile              │    │
│  │ - 폴링 (2초 간격)        │   │                    │  │ → Credential            │    │
│  │ - 결과 반환              │   │                    │  │ → LLM Provider 호출     │    │
│  └─────────────────────────┘   │                    │  └──────────┬─────────────┘    │
│                                │                     │             │                  │
│                                │                     │             ▼                  │
│                                │                     │  ┌────────────────────────┐    │
│                                │                     │  │ ai_analysis_result      │    │
│                                │                     │  └────────────────────────┘    │
└──────────────────────────────┘                      └──────────────────────────────┘
```

### 통신 방식

| 구간 | 방식 | 비고 |
|------|------|------|
| DB1 → ADB | DB Link (INSERT) | 분석 요청 데이터 전송 (5개 CLOB 필드) |
| ADB 내부 | DBMS_SCHEDULER Job | 5초 간격으로 PENDING 요청 감지 → LLM 호출 |
| ADB → LLM | DBMS_CLOUD_AI.GENERATE | AI Profile에 설정된 Provider로 호출 |
| ADB → DB1 | DB Link (SELECT) | 폴링 방식으로 결과 조회 |

---

## 3. 컴포넌트 상세

### 3.1 DB1 — query_analyzer 패키지

**파일**: `src/db1/query_analyzer_pkg.sql`

**수집 데이터 (t_analysis_result)**:

```sql
TYPE t_analysis_result IS RECORD (
    execution_plan   CLOB,    -- DBMS_XPLAN 실행계획
    table_stats      CLOB,    -- 참조 테이블 통계 (JSON)
    index_info       CLOB,    -- 인덱스 정보 (JSON)
    sql_text         CLOB,    -- SQL 원문
    tuning_advice    CLOB     -- DBMS_SQLTUNE 결과 / 스킵 메시지
);
```

**메인 함수**:

```sql
FUNCTION collect_query_info(
    p_sql_text      IN CLOB,
    p_schema        IN VARCHAR2 DEFAULT NULL,
    p_sql_id        IN VARCHAR2 DEFAULT NULL,     -- Standby: SQL_ID 직접 지정
    p_force_standby IN BOOLEAN  DEFAULT FALSE      -- Standby 경로 강제
) RETURN t_analysis_result;
```

**수집 경로 분기**:

| 항목 | Primary 경로 | Standby 경로 |
|------|-------------|-------------|
| 실행계획 | `EXPLAIN PLAN` → `DBMS_XPLAN.DISPLAY` | `DBMS_SQL` 실행 → `DBMS_XPLAN.DISPLAY_CURSOR` |
| 테이블명 추출 | PLAN_TABLE에서 SELECT | V$SQL_PLAN에서 SELECT (동적 SQL) |
| 통계/인덱스 | ALL_TABLES / ALL_INDEXES | ALL_TABLES / ALL_INDEXES (동일) |
| 튜닝 조언 | `DBMS_SQLTUNE` (Case 2) 또는 실패 메시지 (Case 1) | 스킵 메시지 |

**Standby 전용 함수**: `is_standby_db()`, `get_db_role()`, `find_sql_id()`, `get_execution_plan_by_sqlid()`, `extract_table_names_from_cursor()` — 모두 동적 SQL(`EXECUTE IMMEDIATE`)로 V$ 뷰 접근

### 3.2 DB1 — analyze_query() 래퍼 함수

**파일**: `src/db1/analyze_query_func.sql`

```sql
FUNCTION analyze_query(
    p_sql_text      IN CLOB,
    p_schema        IN VARCHAR2 DEFAULT NULL,
    p_timeout       IN NUMBER   DEFAULT 60,
    p_db_link       IN VARCHAR2 DEFAULT 'ADB_LINK',
    p_sql_id        IN VARCHAR2 DEFAULT NULL,       -- Standby: SQL_ID 지정
    p_force_standby IN VARCHAR2 DEFAULT 'N'          -- 'Y'이면 Standby 경로
) RETURN CLOB;
```

**동작 순서**: collect_query_info() → INSERT@ADB_LINK → 폴링(2초 간격) → SELECT 결과 반환

**타임아웃**: 기본 60초, 초과 시 request_id 반환하여 `get_analysis_result()`로 추후 조회

### 3.3 ADB — 요청/결과 테이블

**파일**: `src/adb/tables.sql`

**ai_analysis_request** (요청):

| 컬럼 | 타입 | 설명 |
|------|------|------|
| request_id | NUMBER (시퀀스) | PK |
| sql_text | CLOB | 분석 대상 SQL |
| exec_plan | CLOB | 실행계획 텍스트 |
| table_stats | CLOB | 테이블 통계 (JSON) |
| index_info | CLOB | 인덱스 정보 (JSON) |
| tuning_advice | CLOB | Tuning Advisor 결과 또는 스킵 메시지 |
| status | VARCHAR2(20) | PENDING / PROCESSING / DONE / ERROR |
| error_message | VARCHAR2(4000) | 에러 메시지 |
| source_db | VARCHAR2(128) | 원본 DB 식별자 |
| requested_by | VARCHAR2(128) | 요청자 |
| created_at / updated_at | TIMESTAMP | 시각 |

**ai_analysis_result** (결과):

| 컬럼 | 타입 | 설명 |
|------|------|------|
| result_id | NUMBER (IDENTITY) | PK |
| request_id | NUMBER (FK) | 요청 ID 참조 |
| analysis | CLOB | LLM 분석 결과 전문 |
| model_used | VARCHAR2(200) | 사용된 LLM 모델/프로파일명 |
| elapsed_secs | NUMBER(10,2) | LLM 처리 소요 시간(초) |
| created_at | TIMESTAMP | 결과 생성 시각 |

**ai_analysis_log** (로그): request_id, log_level (INFO/WARN/ERROR/DEBUG), message

### 3.4 ADB — AI 분석 프로세서

**파일**: `src/adb/process_ai_analysis.sql`

**패키지**: `ai_query_processor`

| 함수/프로시저 | 역할 |
|-------------|------|
| `build_prompt()` | 수집 데이터를 LLM 프롬프트로 조합. tuning_advice가 있으면 Advisor 섹션 포함 |
| `process_single_request()` | 단건 처리: 프롬프트 구성 → LLM 호출 (재시도 최대 3회) → 결과 저장 |
| `process_pending_requests()` | 배치 처리: PENDING 요청을 최대 5건씩 처리 (Scheduler Job에서 호출) |

**AI Profile 상수**: `c_ai_profile CONSTANT VARCHAR2(100) := 'QUERY_ANALYZER_GROK4'`

**프롬프트 구조** (6개 분석 항목):

```
당신은 Oracle Database 성능 튜닝 전문가입니다.

## 분석 대상 SQL
## 실행계획 (DBMS_XPLAN)
## 테이블 통계 (JSON)
## 인덱스 정보 (JSON)
## Oracle SQL Tuning Advisor 결과    ← tuning_advice가 있을 때만 포함

## 분석 요청사항
1. 실행계획 요약
2. 성능 병목 분석
3. 인덱스 활용도 평가
4. 최적화된 SQL
5. SQL Tuning Advisor 결과 해석
6. 추가 권고사항
```

### 3.5 ADB — AI Profile + Credential

**파일**: `src/adb/ai_profile_setup.sql`

```
Credential (인증 정보)          AI Profile (LLM 설정)            코드에서 참조
─────────────────────          ────────────────────             ───────────────
DBMS_CLOUD.CREATE_CREDENTIAL    DBMS_CLOUD_AI.CREATE_PROFILE    c_ai_profile 상수
  credential_name                 profile_name ──────────────► 'QUERY_ANALYZER_GROK4'
  user_ocid / API Key             provider (oci/openai/azure)
  private_key / password          credential_name
                                  model, temperature, max_tokens
```

### 3.6 ADB — Scheduler Job

**파일**: `src/adb/scheduler_job.sql`

| Job | 주기 | 호출 대상 |
|-----|------|----------|
| `AI_ANALYSIS_PROCESSOR_JOB` | 5초 | `ai_query_processor.process_pending_requests` |
| `AI_ANALYSIS_PURGE_JOB` | 매일 02:00 | `purge_analysis_history(90)` |

---

## 4. 사전 준비사항

### 4.1 ADB 설정 (순서대로)

| 순서 | 파일 | 내용 |
|------|------|------|
| 1 | `src/adb/tables.sql` | 요청/결과/로그 테이블 + 정리 프로시저 |
| 2 | `src/adb/ai_profile_setup.sql` | Credential + AI Profile 생성 |
| 3 | `src/adb/process_ai_analysis.sql` | AI 프로세서 패키지 |
| 4 | `src/adb/scheduler_job.sql` | Scheduler Job 등록 |

→ 상세: [ADB 설정 및 DB Link 연동 흐름](adb_setup_and_flow.md)

### 4.2 DB Link 설정 (DB1에서)

```sql
CREATE DATABASE LINK ADB_LINK
    CONNECT TO admin IDENTIFIED BY "password"
    USING '(DESCRIPTION=
             (ADDRESS=(PROTOCOL=TCPS)(HOST=adb.ap-seoul-1.oraclecloud.com)(PORT=1522))
             (CONNECT_DATA=(SERVICE_NAME=dbxxxx_medium))
             (SECURITY=(SSL_SERVER_DN_MATCH=YES)
                       (MY_WALLET_DIRECTORY=/path/to/wallet)))';
```

### 4.3 DB1 배포 (DB1에서)

```sql
@src/db1/query_analyzer_pkg.sql    -- 수집 패키지 (Primary + Standby 지원)
@src/db1/analyze_query_func.sql    -- 래퍼 함수
```

### 4.4 권한 요구사항

| 대상 | 필요 권한 |
|------|----------|
| DB1 사용자 | `CREATE PROCEDURE`, `CREATE DATABASE LINK`, 대상 테이블 `SELECT` |
| DB1 (Case 2) | 추가: `ADVISOR`, `EXECUTE ON DBMS_SQLTUNE` |
| DB1 (Case 3) | 추가: V$ 뷰 접근 (`V$DATABASE`, `V$SQL`, `V$SQL_PLAN`) — DBA 역할 |
| ADB 사용자 | `DBMS_CLOUD_AI` 실행 권한, `CREATE TABLE`, `CREATE JOB` |

---

## 5. 고려사항 및 제약

### 5.1 Standby에서 DB Link INSERT

Standby DB에서 DB Link를 통한 원격 INSERT는 원칙적으로 가능(원격 DB에서 쓰기 발생)하나, 분산 트랜잭션 제약으로 실패할 수 있음. → [Case 3 플로우](flow_case3.md)에서 대안 아키텍처 참고

### 5.2 CLOB 전송

- DB Link를 통한 CLOB 전송 시 크기 제약 가능
- 실행계획이 매우 긴 경우 요약/분할 로직 필요

### 5.3 보안

- SQL 텍스트가 외부 LLM으로 전송되므로 민감 데이터 마스킹 고려
- DB Link 비밀번호 관리 (Oracle Wallet 사용 권장)
- `.env` 파일은 `.gitignore`에 포함 — 절대 커밋하지 않을 것

### 5.4 성능

- LLM 응답 시간: 수 초 ~ 수십 초 소요
- 동시 다발 요청 시 ADB 부하 및 LLM API Rate Limit 고려
- 분석 이력 자동 정리: `AI_ANALYSIS_PURGE_JOB`이 90일 경과 데이터 삭제

---

## 6. 프로젝트 디렉토리 구조

```
oracle-ai-query-analyzer/
├── docs/
│   ├── architecture.md              # 본 문서
│   ├── adb_setup_and_flow.md        # ADB 설정 + DB Link 연동 가이드
│   ├── case1_ai_direct_analysis.md  # Case 1: AI 직접 분석
│   ├── case2_with_tuning_pack.md    # Case 2: 튜닝팩 사용
│   ├── case3_standby_db.md          # Case 3: Standby DB
│   ├── flow_case1.md                # Case 1 End-to-End 플로우
│   ├── flow_case2.md                # Case 2 End-to-End 플로우
│   ├── flow_case3.md                # Case 3 End-to-End 플로우
│   ├── report_001.md                # 샘플 리포트 (Case 1)
│   ├── report_002.md                # 샘플 리포트 (Case 2)
│   ├── report_003.md                # 샘플 리포트 (Case 3)
│   └── report_comparison.md         # 리포트 비교 (Case 2 vs 3)
├── src/
│   ├── db1/                         # DB1 배포용
│   │   ├── query_analyzer_pkg.sql   #   핵심 패키지 (Primary + Standby 지원)
│   │   ├── analyze_query_func.sql   #   래퍼 함수 (사용자 인터페이스)
│   │   ├── test_connection.py       #   배포/테스트 스크립트
│   │   ├── test_standby_mode.py     #   Standby 기능 테스트
│   │   └── test_sqltune.py          #   Tuning Pack 권한 테스트
│   ├── adb/                         # ADB 배포용
│   │   ├── tables.sql               #   요청/결과/로그 테이블
│   │   ├── ai_profile_setup.sql     #   Credential + AI Profile
│   │   ├── process_ai_analysis.sql  #   AI 프로세서 패키지
│   │   └── scheduler_job.sql        #   DBMS_SCHEDULER Job
│   └── generate_report.py           # Markdown 리포트 생성기
├── .env                             # 환경 설정 (접속 정보, .gitignore 대상)
└── .env.example                     # 환경 설정 템플릿
```

---

## 7. 구현 로드맵

| 단계 | 내용 | 상태 |
|------|------|------|
| Phase 1 | DB1 query_analyzer 패키지 구현 (Primary + Standby) | DONE |
| Phase 2 | ADB 테이블 및 AI 프로파일 설정 | DONE |
| Phase 3 | ADB AI 분석 프로시저 구현 | DONE |
| Phase 4 | DB1 래퍼 함수 및 통합 테스트 | DONE |
| Phase 5 | 보안/성능 최적화 | TODO |
| Phase 6 | 확장 기능 (AWR 연계, 대시보드 등) | TODO |
