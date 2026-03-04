# Case 2: 튜닝팩 사용 — End-to-End 플로우

> **적용 대상**: Primary DB, Tuning Pack 라이선스 보유
> **핵심**: EXPLAIN PLAN + 통계 + 인덱스 + **DBMS_SQLTUNE 결과**까지 AI에 전달하여 종합 분석

---

## 전체 플로우

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│                                    DB1 (Primary)                                         │
│                                                                                          │
│  사용자 호출:                                                                             │
│  SELECT analyze_query('SELECT * FROM orders WHERE status = ''ACTIVE''') FROM DUAL;       │
│                                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐                  │
│  │  Step 1. analyze_query() — src/db1/analyze_query_func.sql          │                  │
│  │                                                                     │                  │
│  │  1-1. collect_query_info() 호출                                     │                  │
│  │       └─ query_analyzer 패키지 (src/db1/query_analyzer_pkg.sql)    │                  │
│  │                                                                     │                  │
│  │  ┌──────────────────────────────────────────────────────────┐       │                  │
│  │  │  Step 1-1. 실행계획 추출                                  │       │                  │
│  │  │                                                          │       │                  │
│  │  │  EXPLAIN PLAN FOR <SQL>                                  │       │                  │
│  │  │    └─ PLAN_TABLE에 INSERT (쓰기 발생)                    │       │                  │
│  │  │                                                          │       │                  │
│  │  │  DBMS_XPLAN.DISPLAY('PLAN_TABLE', NULL, 'ALL')           │       │                  │
│  │  │    └─ 실행계획 텍스트 추출 → v_result.execution_plan     │       │                  │
│  │  └──────────────────────────────────────────────────────────┘       │                  │
│  │                                                                     │                  │
│  │  ┌──────────────────────────────────────────────────────────┐       │                  │
│  │  │  Step 1-2. 테이블명 추출 + 통계/인덱스 수집              │       │                  │
│  │  │                                                          │       │                  │
│  │  │  PLAN_TABLE에서 참조 테이블명 추출 (SELECT)              │       │                  │
│  │  │    └─ object_type = 'TABLE', object_name IS NOT NULL     │       │                  │
│  │  │                                                          │       │                  │
│  │  │  각 테이블에 대해:                                        │       │                  │
│  │  │    ALL_TABLES   → num_rows, blocks, avg_row_len 등 (JSON)│       │                  │
│  │  │    ALL_INDEXES  → 인덱스명, 컬럼, uniqueness 등 (JSON)   │       │                  │
│  │  └──────────────────────────────────────────────────────────┘       │                  │
│  │                                                                     │                  │
│  │  ┌──────────────────────────────────────────────────────────┐       │                  │
│  │  │  Step 1-3. ★ Tuning Advisor 실행 (Case 2 핵심 차이)      │       │                  │
│  │  │                                                          │       │                  │
│  │  │  get_tuning_advice(p_sql_text):                          │       │                  │
│  │  │                                                          │       │                  │
│  │  │  1) Tuning Task 생성 (쓰기)                              │       │                  │
│  │  │     DBMS_SQLTUNE.CREATE_TUNING_TASK(                     │       │                  │
│  │  │       sql_text    => p_sql_text,                         │       │                  │
│  │  │       time_limit  => 30,                                 │       │                  │
│  │  │       scope       => 'COMPREHENSIVE',                    │       │                  │
│  │  │       task_name   => 'QA_TUNE_' || timestamp             │       │                  │
│  │  │     )                                                    │       │                  │
│  │  │                                                          │       │                  │
│  │  │  2) Tuning Task 실행 (쓰기 — 내부 딕셔너리)              │       │                  │
│  │  │     DBMS_SQLTUNE.EXECUTE_TUNING_TASK(task_name)          │       │                  │
│  │  │                                                          │       │                  │
│  │  │  3) 결과 리포트 추출                                     │       │                  │
│  │  │     DBMS_SQLTUNE.REPORT_TUNING_TASK(task_name)           │       │                  │
│  │  │       └─ SQL Profile 권고, 대체 실행계획, 비교 통계 포함  │       │                  │
│  │  │                                                          │       │                  │
│  │  │  4) Tuning Task 삭제 (정리)                              │       │                  │
│  │  │     DBMS_SQLTUNE.DROP_TUNING_TASK(task_name)             │       │                  │
│  │  │                                                          │       │                  │
│  │  │  v_result.tuning_advice ← DBMS_SQLTUNE 전체 리포트       │       │                  │
│  │  └──────────────────────────────────────────────────────────┘       │                  │
│  │                                                                     │                  │
│  │  수집 완료: v_info (execution_plan, table_stats, index_info,        │                  │
│  │             sql_text, tuning_advice)                                │                  │
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
        │  ★ Case 2에서는 tuning_advice에 DBMS_SQLTUNE 전체 리포트가 포함됨
        │
        ▼
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│                                    ADB (Autonomous DB)                                   │
│                                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐                  │
│  │  Step 3. 요청 저장 — src/adb/tables.sql                            │                  │
│  │                                                                     │                  │
│  │  ai_analysis_request 테이블에 INSERT                                │                  │
│  │    request_id: 시퀀스 자동 채번                                     │                  │
│  │    status: 'PENDING'                                                │                  │
│  │    tuning_advice: DBMS_SQLTUNE 전체 리포트 (CLOB)                   │                  │
│  └─────────────────────────────────────────────────────────────────────┘                  │
│                                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐                  │
│  │  Step 4. Scheduler가 감지 — src/adb/scheduler_job.sql              │                  │
│  │                                                                     │                  │
│  │  AI_ANALYSIS_PROCESSOR_JOB (5초 간격 실행)                          │                  │
│  │    └─ ai_query_processor.process_pending_requests()                 │                  │
│  │         └─ PENDING 요청 조회 → process_single_request() 호출        │                  │
│  └─────────────────────────────────────────────────────────────────────┘                  │
│                                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐                  │
│  │  Step 5. 프롬프트 구성 + LLM 호출 — src/adb/process_ai_analysis.sql│                  │
│  │                                                                     │                  │
│  │  5-1. status → 'PROCESSING'                                        │                  │
│  │                                                                     │                  │
│  │  5-2. build_prompt() — ★ Tuning Advisor 섹션 포함                   │                  │
│  │       ┌─────────────────────────────────────────────┐               │                  │
│  │       │ "당신은 Oracle Database 성능 튜닝 전문가..."   │               │                  │
│  │       │                                             │               │                  │
│  │       │ ## 분석 대상 SQL                             │               │                  │
│  │       │ {sql_text}                                  │               │                  │
│  │       │                                             │               │                  │
│  │       │ ## 실행계획 (DBMS_XPLAN)                     │               │                  │
│  │       │ {exec_plan}                                 │               │                  │
│  │       │                                             │               │                  │
│  │       │ ## 테이블 통계 (JSON)                        │               │                  │
│  │       │ {table_stats}                               │               │                  │
│  │       │                                             │               │                  │
│  │       │ ## 인덱스 정보 (JSON)                        │               │                  │
│  │       │ {index_info}                                │               │                  │
│  │       │                                             │               │                  │
│  │       │ ★ ## Oracle SQL Tuning Advisor 결과          │               │                  │
│  │       │ {tuning_advice}   ← Case 2 핵심!            │               │                  │
│  │       │   GENERAL INFORMATION SECTION               │               │                  │
│  │       │   FINDINGS SECTION (SQL Profile 등)         │               │                  │
│  │       │   EXPLAIN PLANS SECTION (원본 vs 대체)      │               │                  │
│  │       │   Validation results (실측 비교 통계)       │               │                  │
│  │       │                                             │               │                  │
│  │       │ ## 분석 요청사항                             │               │                  │
│  │       │ 1~6항 (Case 1과 동일)                       │               │                  │
│  │       └─────────────────────────────────────────────┘               │                  │
│  │                                                                     │                  │
│  │  5-3. DBMS_CLOUD_AI.GENERATE() — LLM 호출                          │                  │
│  │       ┌──────────────────────────────────────────┐                  │                  │
│  │       │ DBMS_CLOUD_AI.GENERATE(                  │                  │                  │
│  │       │   prompt       => v_prompt,              │                  │                  │
│  │       │   profile_name => 'QUERY_ANALYZER_GROK4',│  ← AI Profile   │                  │
│  │       │   action       => 'chat'                 │    참조          │                  │
│  │       │ )                                        │                  │                  │
│  │       │                                          │                  │                  │
│  │       │ AI Profile이 LLM Provider로 라우팅:      │                  │                  │
│  │       │   provider: "oci" → OCI GenAI 호출       │                  │                  │
│  │       │   credential: OCI_AI_CRED → 인증         │                  │                  │
│  │       │   model: cohere.command-r-plus           │                  │                  │
│  │       │                                          │                  │                  │
│  │       │ (재시도: 최대 3회, exponential backoff)    │                  │                  │
│  │       └──────────────────────────────────────────┘                  │                  │
│  │                                                                     │                  │
│  │  5-4. 결과 저장                                                     │                  │
│  │       INSERT INTO ai_analysis_result                                │                  │
│  │         (request_id, analysis, model_used, elapsed_secs)            │                  │
│  │                                                                     │                  │
│  │  5-5. status → 'DONE'                                               │                  │
│  └─────────────────────────────────────────────────────────────────────┘                  │
│                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────┘
        │
        │  Step 6. DB1이 폴링으로 결과 조회 (DB Link SELECT)
        │
        ▼
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│                                    DB1 (Primary)                                         │
│                                                                                          │
│  analyze_query() 계속:                                                                   │
│                                                                                          │
│  6-1. 폴링 (2초 간격, 최대 60초)                                                         │
│       LOOP                                                                               │
│         SELECT status FROM ai_analysis_request@ADB_LINK WHERE request_id = :id           │
│         EXIT WHEN status = 'DONE' OR 'ERROR'                                             │
│         DBMS_SESSION.SLEEP(2)                                                            │
│       END LOOP                                                                           │
│                                                                                          │
│  6-2. 결과 조회                                                                          │
│       SELECT analysis FROM ai_analysis_result@ADB_LINK WHERE request_id = :id            │
│                                                                                          │
│  6-3. CLOB 결과 반환 → 사용자에게 AI 분석 리포트 출력                                     │
│       (Tuning Advisor 해석 포함 — SQL Profile 적용성, 실측 비교 등)                        │
│                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Case 1과의 차이점

| 단계 | Case 1 | Case 2 |
|------|--------|--------|
| Step 1-3 | DBMS_SQLTUNE 실패/스킵 | **DBMS_SQLTUNE 전체 실행** (CREATE → EXECUTE → REPORT → DROP) |
| Step 2 | tuning_advice = 실패 메시지 | tuning_advice = **DBMS_SQLTUNE 전체 리포트** |
| Step 5-2 | Advisor 섹션 미포함 | **Advisor 섹션 포함** (Findings, Explain Plans, Validation) |
| AI 분석 결과 | 실행계획+통계만으로 분석 | **Oracle 진단 + AI 해석** 종합 (SQL Profile, 대체 플랜, 실측 비교) |
| 소요 시간 | 짧음 (튜닝 분석 없음) | **30초 추가** (DBMS_SQLTUNE time_limit=30) |
| 라이선스 | EE 기본 | **Tuning Pack 필요** |

---

## Tuning Advisor 실행 상세 (Step 1-3)

```sql
-- src/db1/query_analyzer_pkg.sql 내 get_tuning_advice()

-- 1) Task 생성
v_task_name := DBMS_SQLTUNE.CREATE_TUNING_TASK(
    sql_text    => p_sql_text,
    user_name   => v_schema,
    scope       => 'COMPREHENSIVE',
    time_limit  => 30,           -- 최대 30초 분석
    task_name   => 'QA_TUNE_' || TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISSFF2')
);

-- 2) Task 실행 (내부적으로 딕셔너리에 INSERT — Primary에서만 가능)
DBMS_SQLTUNE.EXECUTE_TUNING_TASK(task_name => v_task_name);

-- 3) 리포트 추출
v_report := DBMS_SQLTUNE.REPORT_TUNING_TASK(
    task_name   => v_task_name,
    type        => 'TEXT',
    level       => 'ALL',
    section     => 'ALL'
);

-- 4) 정리
DBMS_SQLTUNE.DROP_TUNING_TASK(task_name => v_task_name);
```

리포트에 포함되는 내용:
- **SQL Profile Finding**: 더 나은 실행계획 발견 시 프로파일 권고
- **대체 실행계획**: 원본 플랜 vs SQL Profile 플랜 비교
- **Validation Results**: 양쪽 플랜을 실제 실행하여 측정한 비교 통계 (Elapsed Time, Buffer Gets, Physical Reads 등)
- **인덱스 권고**: 필요 시 신규 인덱스 DDL 제시

---

## 사용하는 소스 파일

| 위치 | 파일 | 이 플로우에서의 역할 |
|------|------|-------------------|
| DB1 | `src/db1/query_analyzer_pkg.sql` | Step 1: `collect_query_info()` + **`get_tuning_advice()`** |
| DB1 | `src/db1/analyze_query_func.sql` | Step 1~6: 수집 → DB Link INSERT → 폴링 → 결과 반환 |
| DB1 | `src/db1/test_sqltune.py` | **사전 확인**: DBMS_SQLTUNE 권한 검증 |
| ADB | `src/adb/tables.sql` | Step 3: 요청/결과/로그 테이블 (tuning_advice CLOB 컬럼 포함) |
| ADB | `src/adb/ai_profile_setup.sql` | 사전 설정: Credential + AI Profile |
| ADB | `src/adb/process_ai_analysis.sql` | Step 5: `build_prompt()` — **tuning_advice 있으면 Advisor 섹션 포함** |
| ADB | `src/adb/scheduler_job.sql` | Step 4: 5초 간격 PENDING 감지 Job |

---

## AI Profile 연결 구조

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
       │
       ▼
OCI_AI_CRED (Credential)
  user_ocid, tenancy_ocid, private_key, fingerprint
       │
       ▼
OCI Generative AI / OpenAI / Azure  ← Provider로 LLM 호출
```

---

## 사전 확인: Tuning Pack 권한

Case 2를 사용하기 전에 DBMS_SQLTUNE 실행 권한이 있는지 확인해야 합니다.

```bash
cd src/db1
python test_sqltune.py
```

권한 부족 시: DBA에게 `ADVISOR` 권한 부여 요청
```sql
GRANT ADVISOR TO <사용자>;
GRANT EXECUTE ON DBMS_SQLTUNE TO <사용자>;
```

---

## 샘플 결과

→ [report_002.md](report_002.md)
