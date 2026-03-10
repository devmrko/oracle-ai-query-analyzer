# Oracle AI Query Analyzer — 종합 가이드

> 이 문서는 시스템을 처음 접하는 사람을 위한 종합 설명서입니다.

---

## 1. 이 시스템은 무엇인가?

### 해결하려는 문제

Oracle DB에서 느린 SQL 쿼리를 튜닝하려면 DBA가 다음 작업을 **수동으로** 해야 합니다:

1. `EXPLAIN PLAN`으로 실행계획 확인
2. 테이블 통계(건수, 블록 수 등) 확인
3. 인덱스가 제대로 사용되는지 확인
4. 이 정보들을 종합하여 병목 분석
5. 개선된 SQL이나 인덱스 생성 방안 도출

이 과정은 **경험이 필요**하고 **시간이 많이** 걸립니다.

### 해결 방법

이 시스템은 위 과정을 **자동화**합니다:

```
DBA가 할 일: SQL 한 줄만 실행

SELECT analyze_query('느린 쿼리를 여기에 입력') FROM DUAL;

→ 30~60초 후 AI가 분석한 리포트가 반환됩니다:
  - 실행계획 해석
  - 병목 구간 식별
  - 인덱스 권고
  - 개선된 SQL 제시
```

### 작동 원리 (한 줄 요약)

```
DB1에서 쿼리 정보 수집 → DB Link로 ADB에 전송 → ADB가 AI(LLM)로 분석 → 결과 반환
```

---

## 2. 구성 요소

이 시스템은 **2개의 Oracle DB**가 DB Link로 연결되어 동작합니다.

### DB1 (원본 데이터베이스)

- 분석하고 싶은 SQL이 실행되는 **운영 DB**
- Oracle Enterprise Edition (일반 Oracle DB)
- 역할: **데이터 수집** — 실행계획, 테이블 통계, 인덱스 정보를 수집

### ADB (Oracle Autonomous Database)

- Oracle Cloud에서 제공하는 **자율 운영 DB**
- DBMS_CLOUD_AI라는 **내장 AI 기능**이 있음
- 역할: **AI 분석** — 수집된 데이터를 LLM(대형 언어 모델)에 전달하여 분석

### LLM (대형 언어 모델)

- 실제 분석을 수행하는 AI
- OCI Generative AI, OpenAI GPT, Azure OpenAI 등 선택 가능
- ADB의 `DBMS_CLOUD_AI.GENERATE` 함수를 통해 호출

### DB Link

- DB1과 ADB를 연결하는 Oracle의 원격 DB 접속 기능
- DB1에서 `INSERT INTO table@ADB_LINK`처럼 원격 테이블에 접근 가능

---

## 3. 전체 동작 흐름

```
┌──────────────────┐                              ┌──────────────────┐
│   DB1 (운영 DB)   │                              │   ADB (Cloud DB)  │
│                    │                              │                    │
│  ① 사용자가       │                              │                    │
│     analyze_query  │                              │                    │
│     ('SELECT ...')  │                              │                    │
│     호출           │                              │                    │
│                    │                              │                    │
│  ② 실행계획 추출   │                              │                    │
│     EXPLAIN PLAN   │                              │                    │
│     → 실행계획     │                              │                    │
│                    │                              │                    │
│  ③ 테이블 통계     │                              │                    │
│     ALL_TABLES     │                              │                    │
│     → JSON         │                              │                    │
│                    │                              │                    │
│  ④ 인덱스 정보     │                              │                    │
│     ALL_INDEXES    │                              │                    │
│     → JSON         │                              │                    │
│                    │        DB Link               │                    │
│  ⑤ 수집 데이터를   │ ────── INSERT ──────────►   │  ⑥ 요청 저장       │
│     ADB에 전송     │                              │     (PENDING)      │
│                    │                              │                    │
│                    │                              │  ⑦ 5초마다 감지     │
│                    │                              │     Scheduler Job  │
│                    │                              │                    │
│                    │                              │  ⑧ 프롬프트 구성    │
│                    │                              │     SQL + 실행계획  │
│                    │                              │     + 통계 + 인덱스 │
│                    │                              │                    │
│                    │                              │  ⑨ AI 호출          │
│                    │                              │     DBMS_CLOUD_AI  │
│                    │                              │     .GENERATE()    │
│                    │                              │        │           │
│                    │                              │        ▼           │
│                    │                              │     ┌────────┐    │
│                    │                              │     │  LLM   │    │
│                    │                              │     │ (GPT등)│    │
│                    │                              │     └────────┘    │
│                    │                              │        │           │
│                    │                              │  ⑩ 결과 저장       │
│                    │        DB Link               │     (DONE)        │
│  ⑪ 폴링으로       │ ◄───── SELECT ──────────    │                    │
│     결과 조회      │                              │                    │
│                    │                              │                    │
│  ⑫ 사용자에게      │                              │                    │
│     리포트 반환    │                              │                    │
│                    │                              │                    │
└──────────────────┘                              └──────────────────┘
```

### 단계별 설명

| 단계 | 위치 | 설명 |
|------|------|------|
| ① | DB1 | 사용자가 `analyze_query('SELECT ...')` 함수 호출 |
| ② | DB1 | `EXPLAIN PLAN FOR <SQL>` 실행 → `DBMS_XPLAN.DISPLAY`로 실행계획 텍스트 추출 |
| ③ | DB1 | SQL에서 참조하는 테이블들의 통계 정보를 `ALL_TABLES`에서 JSON으로 수집 |
| ④ | DB1 | 참조 테이블들의 인덱스 정보를 `ALL_INDEXES`에서 JSON으로 수집 |
| ⑤ | DB1→ADB | 수집한 데이터 5개(SQL, 실행계획, 통계, 인덱스, 튜닝조언)를 DB Link로 ADB 테이블에 INSERT |
| ⑥ | ADB | `ai_analysis_request` 테이블에 저장, 상태는 `PENDING` |
| ⑦ | ADB | `DBMS_SCHEDULER` Job이 5초마다 PENDING 요청을 감지 |
| ⑧ | ADB | 수집 데이터를 LLM이 이해할 수 있는 프롬프트(질문문)로 조합 |
| ⑨ | ADB | `DBMS_CLOUD_AI.GENERATE()`로 LLM 호출. AI Profile에 설정된 Provider(OCI/OpenAI/Azure)로 전송 |
| ⑩ | ADB | LLM 응답을 `ai_analysis_result` 테이블에 저장, 상태를 `DONE`으로 변경 |
| ⑪ | DB1 | `analyze_query()`가 2초 간격으로 상태를 확인(폴링), `DONE`이면 결과 조회 |
| ⑫ | DB1 | AI 분석 리포트를 CLOB으로 반환 |

---

## 4. 3가지 적용 케이스

동일한 시스템이지만, DB1의 환경에 따라 **데이터 수집 방법**이 달라집니다.

### Case 1: AI 직접 분석 (Tuning Pack 없이)

```
사용 환경: DB1이 Primary DB, Tuning Pack 라이선스 없음
```

- 실행계획 + 테이블 통계 + 인덱스 정보만 수집
- **DBMS_SQLTUNE (Oracle Tuning Advisor)을 사용하지 않음**
- AI가 이 3가지 정보만으로 분석

```sql
-- 이렇게 호출
SELECT analyze_query('SELECT * FROM orders WHERE status = ''ACTIVE''') FROM DUAL;
```

→ [상세 설명](case1_ai_direct_analysis.md) / [플로우](flow_case1.md) / [샘플 리포트](report_001.md)

### Case 2: 튜닝팩 사용 (Advisor + AI 종합 분석)

```
사용 환경: DB1이 Primary DB, Tuning Pack 라이선스 보유
```

- Case 1의 모든 데이터 + **DBMS_SQLTUNE 결과**까지 수집
- Oracle이 자체적으로 SQL Profile, 대체 실행계획, 실측 비교 통계를 생성
- AI가 Oracle의 진단 결과를 **해석**하여 더 풍부한 분석 제공

**DBMS_SQLTUNE이란?**
Oracle이 자체 제공하는 SQL 튜닝 도구입니다. SQL을 분석하여 "SQL Profile을 적용하면 11% 빨라집니다" 같은 구체적인 권고를 제공합니다. 단, **Tuning Pack 라이선스**가 필요합니다.

```sql
-- Case 1과 동일하게 호출 (Tuning Pack 권한이 있으면 자동으로 Case 2 동작)
SELECT analyze_query('SELECT * FROM orders WHERE status = ''ACTIVE''') FROM DUAL;
```

→ [상세 설명](case2_with_tuning_pack.md) / [플로우](flow_case2.md) / [샘플 리포트](report_002.md)

### Case 3: Standby DB (Read-Only 환경)

```
사용 환경: DB1이 Standby DB (Active Data Guard, 읽기 전용)
```

**왜 별도 경로가 필요한가?**

Standby DB는 **읽기 전용**입니다. 그런데 Case 1/2의 일부 작업은 쓰기가 필요합니다:

| 작업 | 쓰기 여부 | Standby에서 |
|------|----------|------------|
| `EXPLAIN PLAN` | PLAN_TABLE에 INSERT | **불가** |
| `DBMS_SQLTUNE` | 내부 딕셔너리에 INSERT | **불가** |
| `ALL_TABLES` 조회 | SELECT (읽기) | 가능 |
| `ALL_INDEXES` 조회 | SELECT (읽기) | 가능 |

**대안 경로:**

| 기능 | Primary (Case 1/2) | Standby (Case 3) |
|------|-------------------|------------------|
| 실행계획 | `EXPLAIN PLAN` → `DBMS_XPLAN.DISPLAY` | SQL 실행 → `DBMS_XPLAN.DISPLAY_CURSOR` |
| 테이블명 추출 | PLAN_TABLE에서 SELECT | **V$SQL_PLAN** 메모리 뷰에서 SELECT |
| 통계/인덱스 | ALL_TABLES / ALL_INDEXES | 동일 |
| Tuning Advisor | DBMS_SQLTUNE 실행 | **스킵** |

Standby에서는 SQL을 먼저 실행하여 Shared Pool(메모리)에 캐싱하고, V$ 메모리 뷰에서 읽기만 수행합니다. 모든 작업이 SELECT뿐이므로 Standby에서 안전합니다.

```sql
-- Standby DB에서 호출 (자동 감지)
SELECT analyze_query('SELECT * FROM orders WHERE status = ''ACTIVE''') FROM DUAL;

-- 또는 Primary에서 Standby 경로를 강제 테스트
SELECT analyze_query(
    p_sql_text      => 'SELECT * FROM orders WHERE status = ''ACTIVE''',
    p_force_standby => 'Y'
) FROM DUAL;
```

→ [상세 설명](case3_standby_db.md) / [플로우](flow_case3.md) / [샘플 리포트](report_003.md)

### 3가지 케이스 비교

| | Case 1 | Case 2 | Case 3 |
|---|--------|--------|--------|
| **DB1 환경** | Primary | Primary | Standby (Read-Only) |
| **라이선스** | EE 기본 | Tuning Pack 필요 | EE 기본 |
| **실행계획 수집** | EXPLAIN PLAN | EXPLAIN PLAN | DISPLAY_CURSOR |
| **Tuning Advisor** | 미사용 | **사용** | 스킵 |
| **AI 분석 범위** | 실행계획+통계+인덱스 | + Advisor 결과 해석 | 실행계획+통계+인덱스 |
| **분석 깊이** | 좋음 | **가장 좋음** | 좋음 |

→ [Case 2 vs 3 상세 비교](report_comparison.md)

---

## 5. ADB의 AI Profile이란?

ADB에서 LLM을 호출하려면 **어떤 AI를, 어떤 인증으로 호출할지** 설정해야 합니다. 이것이 AI Profile입니다.

### 구조

```
┌─────────────────────┐
│  Credential (인증)    │  ← API Key, OCID 등 인증 정보
│  예: OCI_AI_CRED     │
└──────────┬──────────┘
           │ 참조
           ▼
┌─────────────────────┐
│  AI Profile (설정)    │  ← Provider, 모델명, 온도 등 LLM 설정
│  예: QUERY_ANALYZER  │
│       _GROK4         │
└──────────┬──────────┘
           │ 코드에서 참조
           ▼
┌─────────────────────┐
│  process_ai_analysis │  ← 패키지 상수: c_ai_profile := 'QUERY_ANALYZER_GROK4'
│  .sql                │
│                      │     DBMS_CLOUD_AI.GENERATE(
│                      │       prompt => '...',
│                      │       profile_name => c_ai_profile  ← 여기서 사용
│                      │     )
└─────────────────────┘
```

### Credential 생성 (인증 정보 등록)

```sql
-- ADB에서 실행
-- OCI Generative AI 사용 시
BEGIN
    DBMS_CLOUD.CREATE_CREDENTIAL(
        credential_name => 'OCI_AI_CRED',
        user_ocid       => 'ocid1.user.oc1..aaaa...',      -- OCI 사용자 OCID
        tenancy_ocid    => 'ocid1.tenancy.oc1..aaaa...',    -- 테넌시 OCID
        private_key     => '-----BEGIN PRIVATE KEY-----...', -- API 키
        fingerprint     => 'aa:bb:cc:dd:...'                 -- 지문
    );
END;
/
```

### AI Profile 생성 (LLM 설정)

```sql
-- ADB에서 실행
BEGIN
    DBMS_CLOUD_AI.CREATE_PROFILE(
        profile_name => 'QUERY_ANALYZER_GROK4',   -- ★ 이 이름이 코드에서 참조됨
        attributes   => '{
            "provider": "oci",                      -- LLM 제공자
            "credential_name": "OCI_AI_CRED",       -- 위에서 만든 Credential
            "model": "cohere.command-r-plus",        -- 사용할 모델
            "temperature": 0.2,                      -- 답변의 창의성 (0~1, 낮을수록 일관적)
            "max_tokens": 4096                       -- 최대 응답 길이
        }'
    );
END;
/
```

### 지원 LLM Provider

| Provider | 설정값 | 인증 방식 | 비고 |
|----------|--------|----------|------|
| OCI Generative AI | `"provider": "oci"` | OCI API Key | Oracle Cloud 내부 통신, **권장** |
| OpenAI | `"provider": "openai"` | API Key | 외부 네트워크 ACL 필요 |
| Azure OpenAI | `"provider": "azure"` | API Key + Resource | 기업 환경 |

---

## 6. AI에게 보내는 프롬프트 구조

수집한 데이터를 LLM이 이해할 수 있는 형태로 조합합니다. `build_prompt()` 함수가 이 작업을 수행합니다.

```
당신은 Oracle Database 성능 튜닝 전문가입니다.
아래 SQL의 실행계획과 메타데이터를 분석하여 최적화 방안을 제시하세요.

## 분석 대상 SQL
SELECT p.program_title, s.air_datetime, ...
FROM ENM_SCHEDULE s
JOIN ENM_EPISODE e ON ...
WHERE s.channel = 'tvN' AND s.air_datetime >= DATE '2025-01-01'

## 실행계획 (DBMS_XPLAN)
| Id | Operation              | Name         | Rows | Bytes | Cost |
|  0 | SELECT STATEMENT       |              |    3 |   201 |    9 |
|  1 |  SORT ORDER BY         |              |    3 |   201 |    9 |
|  2 |   HASH JOIN            |              |    3 |   201 |    8 |
...

## 테이블 통계 (JSON)
[{"table_name": "ENM_SCHEDULE", "num_rows": 3, "blocks": 1, ...}, ...]

## 인덱스 정보 (JSON)
[{"index_name": "IX_SCHEDULE_AIRDT", "table_name": "ENM_SCHEDULE", ...}, ...]

## Oracle SQL Tuning Advisor 결과       ← Case 2에서만 포함
FINDINGS SECTION: SQL Profile Finding...
Recommendation: estimated benefit 11.15%
...

## 분석 요청사항
1. 실행계획 요약
2. 성능 병목 분석
3. 인덱스 활용도 평가
4. 최적화된 SQL
5. SQL Tuning Advisor 결과 해석
6. 추가 권고사항
```

AI는 이 프롬프트를 받아 6개 항목으로 구분된 분석 리포트를 반환합니다.

---

## 7. 소스 파일 설명

### DB1에 배포하는 파일 (src/db1/)

| 파일 | 설명 |
|------|------|
| **`query_analyzer_pkg.sql`** | **핵심 PL/SQL 패키지**. 실행계획 추출, 테이블 통계 수집, 인덱스 정보 수집, Tuning Advisor 실행을 담당. Primary/Standby 듀얼 모드 지원. `collect_query_info()` 함수가 모든 데이터를 수집하여 레코드로 반환 |
| **`analyze_query_func.sql`** | **사용자 인터페이스 함수**. `analyze_query()`를 호출하면 내부적으로 `collect_query_info()` → DB Link INSERT → 폴링 → 결과 반환까지 자동 처리. `get_analysis_result()` 함수로 타임아웃된 요청을 나중에 조회 가능 |
| `test_connection.py` | 배포 및 기능 테스트 스크립트 (5단계: 접속 → 사전조건 → 패키지 배포 → 함수 배포 → 기능 테스트) |
| `test_standby_mode.py` | Standby 경로 전용 6단계 테스트 (Primary에서 `p_force_standby=TRUE`로 검증) |
| `test_sqltune.py` | Case 2 사전 확인: DBMS_SQLTUNE 실행 권한 검증 |

### ADB에 배포하는 파일 (src/adb/)

| 파일 | 설명 |
|------|------|
| **`tables.sql`** | **테이블 DDL**. `ai_analysis_request`(요청), `ai_analysis_result`(결과), `ai_analysis_log`(로그) 3개 테이블과 시퀀스, 정리 프로시저 생성 |
| **`ai_profile_setup.sql`** | **AI Profile 설정**. Credential 생성 + AI Profile 생성. OCI/OpenAI/Azure 3가지 템플릿 제공. `<<PLACEHOLDER>>`를 실제 값으로 교체하여 사용 |
| **`process_ai_analysis.sql`** | **AI 프로세서 패키지**. `build_prompt()`로 프롬프트 구성, `DBMS_CLOUD_AI.GENERATE()`로 LLM 호출, 재시도(최대 3회) 포함. `c_ai_profile` 상수가 AI Profile을 참조 |
| **`scheduler_job.sql`** | **Scheduler Job 등록**. 5초 간격으로 PENDING 요청 감지하는 Job + 매일 02시 90일 경과 이력 정리 Job |

### 기타

| 파일 | 설명 |
|------|------|
| `src/generate_report.py` | ADB의 분석 결과를 Markdown 리포트로 변환하는 Python 스크립트 |
| `.env` | DB 접속 정보 (비밀번호 포함, **절대 공개 금지**, `.gitignore`에 포함) |
| `.env.example` | `.env`의 템플릿 (빈 값) |

---

## 8. 설치 방법

### 사전 준비

- DB1: Oracle Enterprise Edition (운영 DB)
- ADB: Oracle Autonomous Database (Oracle Cloud)
- DB1 → ADB 네트워크 통신 가능
- ADB에서 외부 AI Provider 접근 가능 (OCI 내부 통신 또는 외부 네트워크 ACL)

### Step 1: ADB 설정 (ADB에서 순서대로 실행)

```sql
-- 1) 테이블 생성
@src/adb/tables.sql

-- 2) Credential + AI Profile 생성
--    ai_profile_setup.sql의 <<PLACEHOLDER>>를 실제 값으로 교체 후 실행
@src/adb/ai_profile_setup.sql

-- 3) AI 프로세서 패키지 배포
@src/adb/process_ai_analysis.sql

-- 4) Scheduler Job 등록
@src/adb/scheduler_job.sql
```

### Step 2: DB Link 생성 (DB1에서 실행)

```sql
CREATE DATABASE LINK ADB_LINK
    CONNECT TO admin IDENTIFIED BY "password"
    USING '(DESCRIPTION=
             (ADDRESS=(PROTOCOL=TCPS)(HOST=adb.ap-seoul-1.oraclecloud.com)(PORT=1522))
             (CONNECT_DATA=(SERVICE_NAME=dbxxxx_medium))
             (SECURITY=(SSL_SERVER_DN_MATCH=YES)
                       (MY_WALLET_DIRECTORY=/path/to/wallet)))';

-- 연결 확인
SELECT * FROM DUAL@ADB_LINK;
```

### Step 3: DB1 배포 (DB1에서 실행)

```sql
-- 1) 수집 패키지
@src/db1/query_analyzer_pkg.sql

-- 2) 래퍼 함수
@src/db1/analyze_query_func.sql
```

### Step 4: 테스트

```bash
cd src/db1
python test_connection.py        # 기본 배포 + 기능 테스트
python test_sqltune.py           # (Case 2) Tuning Pack 권한 확인
python test_standby_mode.py      # (Case 3) Standby 경로 검증
```

---

## 9. 사용법

### 기본 사용 (Case 1/2)

```sql
-- 분석하고 싶은 SQL을 넣으면 됩니다
SELECT analyze_query(
    'SELECT e.employee_name, d.department_name
     FROM employees e
     JOIN departments d ON e.dept_id = d.id
     WHERE e.salary > 50000
     ORDER BY e.salary DESC'
) FROM DUAL;
```

30~60초 후 AI 분석 리포트가 CLOB으로 반환됩니다.

### Standby DB에서 사용 (Case 3)

```sql
-- 방법 1: Standby DB에 접속하면 자동 감지
SELECT analyze_query('SELECT ...') FROM DUAL;

-- 방법 2: Primary에서 Standby 경로 강제
SELECT analyze_query(
    p_sql_text      => 'SELECT ...',
    p_force_standby => 'Y'
) FROM DUAL;

-- 방법 3: SQL_ID를 미리 알 때 (검색 과정 생략)
SELECT analyze_query(
    p_sql_text      => 'SELECT ...',
    p_sql_id        => '5x062n59sxus4',
    p_force_standby => 'Y'
) FROM DUAL;
```

### 타임아웃 시 결과 조회

```sql
-- 기본 60초 내에 완료되지 않으면 request_id가 반환됩니다
-- 나중에 이 ID로 결과를 조회할 수 있습니다
SELECT get_analysis_result(42) FROM DUAL;

-- 타임아웃 시간을 늘릴 수도 있습니다
SELECT analyze_query(
    p_sql_text => 'SELECT ...',
    p_timeout  => 120    -- 120초
) FROM DUAL;
```

### 파라미터 전체 목록

| 파라미터 | 기본값 | 설명 |
|---------|--------|------|
| `p_sql_text` | (필수) | 분석할 SQL 문 |
| `p_schema` | 현재 사용자 | 대상 스키마 |
| `p_timeout` | 60 | 최대 대기 시간(초) |
| `p_db_link` | `'ADB_LINK'` | ADB DB Link 이름 |
| `p_sql_id` | NULL | Standby: V$SQL의 SQL_ID 직접 지정 |
| `p_force_standby` | `'N'` | `'Y'`이면 Standby 경로 강제 |

---

## 10. AI 분석 리포트 예시

AI가 반환하는 리포트는 6개 섹션으로 구성됩니다:

### 1. 실행계획 요약
```
- Operation Id 5: ENM_SCHEDULE에 대한 Full Table Scan으로 시작.
  WHERE 조건(channel = 'tvN' AND air_datetime >= '2025-01-01')을 필터링하며 3행 추출.
- Operation Id 4-7: NESTED LOOPS OUTER로 ENM_AD_DELIVERY와 LEFT JOIN.
  IX_DELIVERY_SCHEDULE 인덱스를 사용한 INDEX RANGE SCAN.
...
```

### 2. 성능 병목 분석
```
- ENM_SCHEDULE Full Table Scan: channel 인덱스의 distinct_keys=1로
  선택도가 낮아 옵티마이저가 Full Scan 선택.
```

### 3. 인덱스 활용도 평가
```
- 사용: IX_DELIVERY_SCHEDULE (LEFT JOIN 시 활용)
- 미사용: IX_SCHEDULE_AIRDT (범위 조건에 적합하나 Full Scan 선택됨)
- 신규 인덱스 권고:
  CREATE INDEX IX_SCHEDULE_CHANNEL_AIRDT ON ENM_SCHEDULE (CHANNEL, AIR_DATETIME);
```

### 4. 최적화된 SQL
```sql
SELECT /*+ LEADING(s) USE_NL(e p) INDEX(s IX_SCHEDULE_CHANNEL_AIRDT) */
       p.program_title, s.air_datetime, ...
```

### 5. SQL Tuning Advisor 결과 해석 (Case 2만 상세)
```
- SQL Profile 적용 시 Buffer Gets 11.11% 감소, Elapsed Time 43.6% 감소
- 적용: DBMS_SQLTUNE.ACCEPT_SQL_PROFILE(task_name => '...')
```

### 6. 추가 권고사항
```
- 통계 갱신: 현재 최신 상태, 추가 갱신 불필요
- 대규모 데이터 시: ENM_SCHEDULE을 air_datetime 기준 RANGE 파티셔닝 고려
```

→ 전체 샘플: [Case 1](report_001.md) / [Case 2](report_002.md) / [Case 3](report_003.md)

---

## 11. 권한 요구사항

### DB1

| 권한 | 대상 | 비고 |
|------|------|------|
| `CREATE PROCEDURE` | 패키지/함수 생성 | 필수 |
| `CREATE DATABASE LINK` | ADB DB Link 생성 | 필수 |
| 대상 테이블 `SELECT` | 통계/인덱스 조회 | 필수 |
| `ADVISOR`, `EXECUTE ON DBMS_SQLTUNE` | Tuning Advisor | Case 2만 |
| V$ 뷰 접근 (DBA 역할) | `V$DATABASE`, `V$SQL`, `V$SQL_PLAN` | Case 3만 |

### ADB

| 권한 | 비고 |
|------|------|
| `DBMS_CLOUD_AI` 실행 | LLM 호출 |
| `DBMS_CLOUD` 실행 | Credential 생성 |
| `CREATE TABLE` | 테이블 생성 |
| `CREATE JOB` | Scheduler Job 등록 |

---

## 12. 문서 목록

| 문서 | 설명 |
|------|------|
| [README.md](../README.md) | 프로젝트 소개 |
| **본 문서 (overview.md)** | 종합 가이드 |
| [architecture.md](architecture.md) | 시스템 아키텍처, 컴포넌트 상세, 로드맵 |
| [adb_setup_and_flow.md](adb_setup_and_flow.md) | ADB 설정 절차, DB Link 구성, 트러블슈팅 |
| [case1_ai_direct_analysis.md](case1_ai_direct_analysis.md) | Case 1 상세 |
| [case2_with_tuning_pack.md](case2_with_tuning_pack.md) | Case 2 상세 |
| [case3_standby_db.md](case3_standby_db.md) | Case 3 상세 |
| [flow_case1.md](flow_case1.md) | Case 1 End-to-End 플로우 |
| [flow_case2.md](flow_case2.md) | Case 2 End-to-End 플로우 |
| [flow_case3.md](flow_case3.md) | Case 3 End-to-End 플로우 |
| [report_001.md](report_001.md) | 샘플 리포트 (Case 1) |
| [report_002.md](report_002.md) | 샘플 리포트 (Case 2) |
| [report_003.md](report_003.md) | 샘플 리포트 (Case 3) |
| [report_comparison.md](report_comparison.md) | Case 2 vs 3 리포트 비교 |
