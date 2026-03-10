# ADB 설정 및 DB Link 연동 흐름

> DB1에서 `analyze_query()`를 호출하면, ADB의 AI 프로파일을 통해 LLM 분석이 수행되고 결과가 반환되기까지의 전체 흐름을 설명합니다.

---

## 1. 전체 흐름 요약

> 3가지 케이스별 상세 플로우는 별도 문서를 참고하세요:
> - [Case 1 플로우](flow_case1.md) — AI 직접 분석 (Tuning Pack 없이)
> - [Case 2 플로우](flow_case2.md) — 튜닝팩 사용 (Advisor + AI 종합 분석)
> - [Case 3 플로우](flow_case3.md) — Standby DB (Read-Only 환경)

```
사용자 (DB1)                         DB Link                    ADB (Autonomous DB)
───────────                         ───────                    ──────────────────
                                                               [사전 설정]
                                                               ① Credential 생성
                                                               ② AI Profile 생성
                                                               ③ 테이블 생성
                                                               ④ Processor 패키지 배포
                                                               ⑤ Scheduler Job 등록

analyze_query('SELECT ...')
  │
  ├─ collect_query_info()
  │   실행계획 + 통계 + 인덱스 수집
  │
  ├─ INSERT INTO
  │   ai_analysis_request@ADB_LINK  ──────►  요청 저장 (PENDING)
  │
  │                                          DBMS_SCHEDULER (5초 간격)
  │                                            │
  │                                            ▼
  │                                          ai_query_processor.process_single_request()
  │                                            │
  │                                            ├─ build_prompt() → 프롬프트 구성
  │                                            │
  │                                            ├─ DBMS_CLOUD_AI.GENERATE(
  │                                            │      prompt => v_prompt,
  │                                            │      profile_name => 'QUERY_ANALYZER_GROK4',
  │                                            │      action       => 'chat'
  │                                            │  )
  │                                            │      │
  │                                            │      ▼
  │                                            │   [LLM Provider]
  │                                            │   OCI / OpenAI / Azure
  │                                            │      │
  │                                            │      ▼
  │                                            │   AI 분석 결과 반환
  │                                            │
  │                                            ├─ INSERT INTO ai_analysis_result
  │                                            └─ status → 'DONE'
  │
  ├─ 폴링 (2초 간격)
  │   SELECT status
  │   FROM ai_analysis_request@ADB_LINK  ◄────  status = 'DONE'
  │
  ├─ SELECT analysis
  │   FROM ai_analysis_result@ADB_LINK  ◄─────  LLM 분석 결과
  │
  └─ 결과 반환 (CLOB)
```

---

## 2. ADB 사전 설정 (1회)

ADB에 아래 4개 파일을 **순서대로** 실행합니다.

### Step 1: 테이블 생성 — `src/adb/tables.sql`

```sql
-- ADB에서 실행
@tables.sql
```

생성되는 객체:

| 객체 | 설명 |
|------|------|
| `ai_analysis_request` | 분석 요청 테이블 (sql_text, exec_plan, table_stats, index_info, tuning_advice, status) |
| `ai_analysis_result` | 분석 결과 테이블 (analysis CLOB, model_used, elapsed_secs) |
| `ai_analysis_log` | 처리 로그 테이블 (log_level, message) |
| `purge_analysis_history()` | 보관 기간 지난 이력 삭제 프로시저 |

### Step 2: AI 프로파일 생성 — `src/adb/ai_profile_setup.sql`

LLM을 호출하려면 **Credential**과 **AI Profile** 두 가지가 필요합니다.

#### 2-1. Credential 생성

LLM 프로바이더의 인증 정보를 Oracle Credential로 등록합니다.

```sql
-- OCI Generative AI 사용 시
BEGIN
    DBMS_CLOUD.CREATE_CREDENTIAL(
        credential_name => 'OCI_AI_CRED',
        user_ocid       => 'ocid1.user.oc1..aaaa...',
        tenancy_ocid    => 'ocid1.tenancy.oc1..aaaa...',
        private_key     => '-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----',
        fingerprint     => 'aa:bb:cc:dd:...'
    );
END;
/

-- OpenAI 사용 시
BEGIN
    DBMS_CLOUD.CREATE_CREDENTIAL(
        credential_name => 'OPENAI_CRED',
        username        => 'OPENAI',
        password        => 'sk-...'    -- OpenAI API Key
    );
END;
/
```

#### 2-2. AI Profile 생성

Credential을 참조하여 AI Profile을 생성합니다. **Profile 이름이 코드에서 사용되는 핵심 연결고리**입니다.

```sql
BEGIN
    DBMS_CLOUD_AI.CREATE_PROFILE(
        profile_name => 'QUERY_ANALYZER_GROK4',    -- ★ 이 이름이 코드에서 참조됨
        attributes   => '{
            "provider": "oci",
            "credential_name": "OCI_AI_CRED",
            "model": "cohere.command-r-plus",
            "oci_compartment_id": "ocid1.compartment.oc1..aaaa...",
            "temperature": 0.2,
            "max_tokens": 4096
        }'
    );
END;
/
```

#### Profile 이름과 코드의 연결

`process_ai_analysis.sql`의 패키지 상수가 이 Profile 이름을 참조합니다:

```sql
-- src/adb/process_ai_analysis.sql (line 22)
c_ai_profile CONSTANT VARCHAR2(100) := 'QUERY_ANALYZER_GROK4';  -- ★ 여기서 참조
```

LLM 호출 시 이 상수가 사용됩니다:

```sql
-- src/adb/process_ai_analysis.sql (line 229-233)
v_ai_result := DBMS_CLOUD_AI.GENERATE(
    prompt       => v_prompt,
    profile_name => c_ai_profile,    -- → 'QUERY_ANALYZER_GROK4'
    action       => 'chat'
);
```

> **Profile 이름을 변경하려면** `ai_profile_setup.sql`의 `profile_name`과 `process_ai_analysis.sql`의 `c_ai_profile` 상수를 **둘 다** 수정해야 합니다.

#### 지원 프로바이더

| 프로바이더 | provider 값 | Credential | 비고 |
|-----------|-------------|------------|------|
| OCI Generative AI | `"oci"` | OCI API Key (OCID + Private Key) | Oracle Cloud 내부 통신, 권장 |
| OpenAI | `"openai"` | API Key | 외부 네트워크 ACL 필요 |
| Azure OpenAI | `"azure"` | API Key + Resource/Deployment Name | 기업 환경 |

#### Profile 확인

```sql
SELECT * FROM user_cloud_ai_profiles;
```

### Step 3: AI Processor 패키지 배포 — `src/adb/process_ai_analysis.sql`

```sql
-- ADB에서 실행
@process_ai_analysis.sql
```

이 패키지가 하는 일:

| 함수/프로시저 | 역할 |
|-------------|------|
| `build_prompt()` | 수집 데이터(SQL + 실행계획 + 통계 + 인덱스 + 튜닝조언)를 LLM 프롬프트로 조합 |
| `process_single_request()` | 단건 요청 처리: 프롬프트 구성 → LLM 호출 (재시도 포함) → 결과 저장 |
| `process_pending_requests()` | PENDING 요청을 배치로 처리 (Scheduler Job이 호출) |

### Step 4: Scheduler Job 등록 — `src/adb/scheduler_job.sql`

```sql
-- ADB에서 실행
@scheduler_job.sql
```

등록되는 Job:

| Job | 주기 | 역할 |
|-----|------|------|
| `AI_ANALYSIS_PROCESSOR_JOB` | **5초 간격** | PENDING 요청 감지 → `process_pending_requests()` 호출 |
| `AI_ANALYSIS_PURGE_JOB` | 매일 02:00 | 90일 지난 이력 자동 삭제 |

---

## 3. DB Link 설정 (DB1에서 1회)

DB1에서 ADB로의 DB Link를 생성합니다. ADB는 TCPS(TLS) 접속만 허용하므로 Wallet 설정이 필수입니다.

> **TCPS DB Link 상세 가이드**: [DB Link TCPS 가이드](dblink_tcps_guide.md) — ADB → DB1 방향, Wallet 설정, 네트워크 ACL, 트러블슈팅

```sql
-- ADB에서 실행 (권장: DBMS_CLOUD 사용)
BEGIN
    DBMS_CLOUD.CREATE_DATABASE_LINK(
        db_link_name => 'DB1_LINK',
        hostname     => '<db1_host>',
        port         => 1521,
        service_name => '<db1_service_name>',
        username     => '<db1_user>',
        password     => '<db1_password>'
    );
END;
/
```

확인:

```sql
SELECT * FROM DUAL@ADB_LINK;  -- 연결 확인
```

---

## 4. DB1 패키지/함수 배포 (DB1에서 1회)

```sql
-- DB1에서 실행
@src/db1/query_analyzer_pkg.sql    -- 수집 패키지
@src/db1/analyze_query_func.sql    -- 래퍼 함수
```

---

## 5. 실행 시 상세 흐름

케이스별 상세 플로우는 별도 문서를 참고하세요:

- [Case 1 플로우](flow_case1.md) — Primary, Tuning Pack 없이
- [Case 2 플로우](flow_case2.md) — Primary, Tuning Pack 사용
- [Case 3 플로우](flow_case3.md) — Standby (Read-Only), DB Link 제약 및 대안 포함

---

## 6. 설정 변경 가이드

### AI Profile (LLM 모델) 변경

```sql
-- ADB에서 실행
-- 1) 기존 프로파일 삭제
BEGIN
    DBMS_CLOUD_AI.DROP_PROFILE(profile_name => 'QUERY_ANALYZER_GROK4');
END;
/

-- 2) 새 프로파일 생성 (같은 이름으로)
BEGIN
    DBMS_CLOUD_AI.CREATE_PROFILE(
        profile_name => 'QUERY_ANALYZER_GROK4',
        attributes   => '{
            "provider": "openai",
            "credential_name": "OPENAI_CRED",
            "model": "gpt-4o",
            "temperature": 0.2,
            "max_tokens": 4096
        }'
    );
END;
/
```

> **프로파일 이름을 동일하게** 유지하면 `process_ai_analysis.sql`의 `c_ai_profile` 상수를 수정할 필요가 없습니다.

### DB Link 변경

```sql
-- DB1에서 실행
-- analyze_query() 호출 시 p_db_link 파라미터로 지정
SELECT analyze_query(
    p_sql_text => 'SELECT ...',
    p_db_link  => 'MY_OTHER_ADB_LINK'    -- 기본값: 'ADB_LINK'
) FROM DUAL;
```

### Scheduler Job 간격 변경

```sql
-- ADB에서 실행 (5초 → 10초로 변경)
BEGIN
    DBMS_SCHEDULER.SET_ATTRIBUTE(
        name      => 'AI_ANALYSIS_PROCESSOR_JOB',
        attribute => 'repeat_interval',
        value     => 'FREQ=SECONDLY;INTERVAL=10'
    );
END;
/
```

---

## 7. 트러블슈팅

### AI Profile 관련

```sql
-- 프로파일 존재 여부 확인
SELECT * FROM user_cloud_ai_profiles;

-- 프로파일 테스트 (직접 LLM 호출)
SELECT DBMS_CLOUD_AI.GENERATE(
    prompt       => '테스트입니다. 1+1은?',
    profile_name => 'QUERY_ANALYZER_GROK4',
    action       => 'chat'
) FROM DUAL;
```

### DB Link 관련

```sql
-- DB Link 연결 확인
SELECT * FROM DUAL@ADB_LINK;

-- ADB 테이블 접근 확인
SELECT COUNT(*) FROM ai_analysis_request@ADB_LINK;
```

### Scheduler Job 관련

```sql
-- ADB에서 실행
-- Job 상태 확인
SELECT job_name, enabled, state, last_start_date, next_run_date, run_count, failure_count
FROM user_scheduler_jobs
WHERE job_name LIKE 'AI_ANALYSIS%';

-- 처리 로그 확인
SELECT * FROM ai_analysis_log ORDER BY created_at DESC FETCH FIRST 20 ROWS ONLY;

-- 요청 상태 확인
SELECT request_id, status, error_message, created_at
FROM ai_analysis_request ORDER BY created_at DESC FETCH FIRST 10 ROWS ONLY;
```
