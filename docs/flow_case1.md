# Case 1: AI 직접 분석 — End-to-End 플로우

> **적용 대상**: Primary DB, Tuning Pack 라이선스 없음
> **핵심**: EXPLAIN PLAN + 통계 + 인덱스를 AI가 직접 분석 (DBMS_SQLTUNE 미사용)

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
│  │  │  Step 1-3. Tuning Advisor                                │       │                  │
│  │  │                                                          │       │                  │
│  │  │  DBMS_SQLTUNE 호출 시도                                  │       │                  │
│  │  │    └─ 권한 없음 / 라이선스 미보유 → 실패 메시지 저장      │       │                  │
│  │  │       "Tuning Pack이 없거나 권한이 없어 실행 불가"        │       │                  │
│  │  │                                                          │       │                  │
│  │  │  v_result.tuning_advice ← 실패 메시지                    │       │                  │
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
│  │  5-2. build_prompt() — 프롬프트 조합                                │                  │
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
│  │       │ ★ Tuning Advisor 섹션: 포함되지 않음         │               │                  │
│  │       │   (tuning_advice가 실패 메시지이므로          │               │                  │
│  │       │    build_prompt()에서 조건부 제외 가능)       │               │                  │
│  │       │                                             │               │                  │
│  │       │ ## 분석 요청사항                             │               │                  │
│  │       │ 1. 실행계획 요약                             │               │                  │
│  │       │ 2. 성능 병목 분석                            │               │                  │
│  │       │ 3. 인덱스 활용도 평가                        │               │                  │
│  │       │ 4. 최적화된 SQL                              │               │                  │
│  │       │ 5. SQL Tuning Advisor 결과 해석              │               │                  │
│  │       │ 6. 추가 권고사항                             │               │                  │
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
│  │       │                                          │                  │
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
│                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 사용하는 소스 파일

| 위치 | 파일 | 이 플로우에서의 역할 |
|------|------|-------------------|
| DB1 | `src/db1/query_analyzer_pkg.sql` | Step 1: `collect_query_info()` — EXPLAIN PLAN + 통계 + 인덱스 수집 |
| DB1 | `src/db1/analyze_query_func.sql` | Step 1~6: `analyze_query()` — 수집 → DB Link INSERT → 폴링 → 결과 반환 |
| ADB | `src/adb/tables.sql` | Step 3: 요청/결과/로그 테이블 DDL |
| ADB | `src/adb/ai_profile_setup.sql` | 사전 설정: Credential + AI Profile 생성 |
| ADB | `src/adb/process_ai_analysis.sql` | Step 5: `build_prompt()` + `DBMS_CLOUD_AI.GENERATE()` 호출 |
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

## Case 1 특징

- **Tuning Advisor 미사용**: DBMS_SQLTUNE 호출이 실패하거나 스킵되어 tuning_advice에 실패 메시지가 저장됨
- **프롬프트에서 Advisor 섹션 제외**: build_prompt()는 tuning_advice가 의미 있는 내용일 때만 프롬프트에 포함
- **AI가 실행계획 + 통계 + 인덱스만으로 분석**: Tuning Advisor 없이도 병목 식별, 인덱스 권고, SQL 개선안 제시 가능
- **라이선스**: Oracle EE 기본 — 별도 Tuning Pack 불필요

---

## 샘플 결과

→ [report_001.md](report_001.md)
