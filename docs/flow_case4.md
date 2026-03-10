# Case 4: ADG + SQL Tuning Advisor — End-to-End 플로우

> **적용 대상**: Standby DB (Active Data Guard) + Tuning Pack 라이선스 보유
> **핵심**: Standby에서 V$ 뷰로 수집 + `database_link_to`로 Primary에 Tuning Advisor 위임

---

## Standby에서 불가능한 작업과 Case 4의 해결

| 작업 | Standby 제약 | Case 3 대안 | Case 4 대안 |
|------|-------------|-------------|-------------|
| `EXPLAIN PLAN` | PLAN_TABLE INSERT 불가 | DISPLAY_CURSOR | DISPLAY_CURSOR (동일) |
| `DBMS_SQLTUNE` | 내부 딕셔너리 INSERT 불가 | **스킵** | **database_link_to로 Primary 위임** |
| ALL_TABLES/INDEXES | SELECT만 (가능) | 동일 | 동일 |

---

## 전체 플로우

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│                              DB1 (Standby / Read-Only)                                   │
│                                                                                          │
│  사용자 호출:                                                                             │
│  SELECT analyze_query(                                                                   │
│      p_sql_text        => 'SELECT * FROM orders WHERE status = ''ACTIVE''',              │
│      p_force_standby   => 'Y',                                                          │
│      p_primary_db_link => 'LNK_TO_PRI'     -- ★ Case 4 핵심 파라미터                    │
│  ) FROM DUAL;                                                                            │
│                                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐                  │
│  │  Step 1. analyze_query() — src/db1/analyze_query_func.sql          │                  │
│  │                                                                     │                  │
│  │  1-1. collect_query_info(                                           │                  │
│  │         p_force_standby   => TRUE,                                  │                  │
│  │         p_primary_db_link => 'LNK_TO_PRI'                          │                  │
│  │       )                                                             │                  │
│  │       └─ query_analyzer 패키지 (src/db1/query_analyzer_pkg.sql)    │                  │
│  │                                                                     │                  │
│  │  ┌──────────────────────────────────────────────────────────┐       │                  │
│  │  │  Step 1-0. Standby 감지 (Case 3과 동일)                  │       │                  │
│  │  │                                                          │       │                  │
│  │  │  v_use_standby := p_force_standby OR is_standby_db()     │       │                  │
│  │  │    → TRUE → Standby 경로 진입                            │       │                  │
│  │  └──────────────────────────────────────────────────────────┘       │                  │
│  │                                                                     │                  │
│  │  ┌──────────────────────────────────────────────────────────┐       │                  │
│  │  │  Step 1-1 ~ 1-4. 데이터 수집 (Case 3과 동일)             │       │                  │
│  │  │                                                          │       │                  │
│  │  │  1-1. SQL_ID 확보 (DBMS_SQL → find_sql_id)              │       │                  │
│  │  │  1-2. DISPLAY_CURSOR 실행계획 추출                       │       │                  │
│  │  │  1-3. V$SQL_PLAN에서 테이블명 추출                       │       │                  │
│  │  │  1-4. ALL_TABLES / ALL_INDEXES 통계 수집                │       │                  │
│  │  └──────────────────────────────────────────────────────────┘       │                  │
│  │                                                                     │                  │
│  │  ┌──────────────────────────────────────────────────────────┐       │                  │
│  │  │  Step 1-5. ★★ ADG SQL Tuning Advisor (Case 4 핵심!)      │       │                  │
│  │  │                                                          │       │                  │
│  │  │  p_primary_db_link IS NOT NULL 이므로 ADG 경로 진입      │       │                  │
│  │  │                                                          │       │                  │
│  │  │  get_tuning_advice_via_adg(                              │       │                  │
│  │  │    p_sql_text        => p_sql_text,                      │       │                  │
│  │  │    p_primary_db_link => 'LNK_TO_PRI',                   │       │                  │
│  │  │    p_time_limit      => 30                               │       │                  │
│  │  │  )                                                       │       │                  │
│  │  │                                                          │       │                  │
│  │  │  1) Tuning Task 생성 (★ database_link_to 사용)           │       │                  │
│  │  │     DBMS_SQLTUNE.CREATE_TUNING_TASK(                     │       │                  │
│  │  │       sql_text         => p_sql_text,                    │       │                  │
│  │  │       time_limit       => 30,                            │       │                  │
│  │  │       task_name        => 'QA_ADG_<timestamp>',          │       │                  │
│  │  │       database_link_to => 'LNK_TO_PRI'  ★ Primary 위임  │       │                  │
│  │  │     )                                                    │       │                  │
│  │  │     → Standby에서 명령, Task 데이터는 Primary에 저장     │       │                  │
│  │  │                                                          │       │                  │
│  │  │  2) Tuning Task 실행                                     │       │                  │
│  │  │     DBMS_SQLTUNE.EXECUTE_TUNING_TASK(task_name)          │       │                  │
│  │  │     → Primary에서 실제 분석 수행                         │       │                  │
│  │  │     → SQL Profile 후보 탐색, 대체 실행계획 비교          │       │                  │
│  │  │                                                          │       │                  │
│  │  │  3) 리포트 추출                                          │       │                  │
│  │  │     DBMS_SQLTUNE.REPORT_TUNING_TASK(task_name)           │       │                  │
│  │  │     → Primary에서 리포트 구성, Standby로 전달            │       │                  │
│  │  │                                                          │       │                  │
│  │  │  4) Task 정리                                            │       │                  │
│  │  │     DBMS_SQLTUNE.DROP_TUNING_TASK(task_name)             │       │                  │
│  │  │                                                          │       │                  │
│  │  │  v_result.tuning_advice ← DBMS_SQLTUNE 리포트 (CLOB)    │       │                  │
│  │  │                                                          │       │                  │
│  │  │  ★ Case 3은 여기서 스킵 메시지를 넣지만,                │       │                  │
│  │  │    Case 4는 실제 Tuning Advisor 리포트가 들어감          │       │                  │
│  │  └──────────────────────────────────────────────────────────┘       │                  │
│  │                                                                     │                  │
│  │  수집 완료: v_info (execution_plan, table_stats, index_info,        │                  │
│  │             sql_text, tuning_advice)                                │                  │
│  │                                                                     │                  │
│  │  ★ Standby 로컬에는 읽기만 수행                                    │                  │
│  │  ★ Tuning 분석은 Primary에서 수행 (database_link_to)               │                  │
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
        │  ★ Case 4: tuning_advice에 ADG를 통한 DBMS_SQLTUNE 리포트 포함
        │    (Case 2와 동일한 내용 — SQL Profile, 대체 실행계획, 실측 비교)
        │
        ▼
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│                                    ADB (Autonomous DB)                                   │
│                                                                                          │
│  ★ ADB 쪽 처리는 Case 1/2/3과 완전히 동일                                               │
│                                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐                  │
│  │  Step 3~4. 요청 저장 + Scheduler 감지 (동일)                       │                  │
│  └─────────────────────────────────────────────────────────────────────┘                  │
│                                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐                  │
│  │  Step 5. 프롬프트 구성 + LLM 호출                                  │                  │
│  │                                                                     │                  │
│  │  5-2. build_prompt() — ★ Tuning Advisor 섹션 포함 (Case 2와 동일)  │                  │
│  │       ┌─────────────────────────────────────────────┐               │                  │
│  │       │ ## 분석 대상 SQL                             │               │                  │
│  │       │ ## 실행계획 (DISPLAY_CURSOR 형식)            │               │                  │
│  │       │ ## 테이블 통계 (JSON)                        │               │                  │
│  │       │ ## 인덱스 정보 (JSON)                        │               │                  │
│  │       │ ★ ## Oracle SQL Tuning Advisor 결과          │               │                  │
│  │       │   (ADG를 통해 Primary에서 실행한 결과)       │               │                  │
│  │       │ ## 분석 요청사항 (1~6항)                     │               │                  │
│  │       └─────────────────────────────────────────────┘               │                  │
│  │                                                                     │                  │
│  │  5-3. DBMS_CLOUD_AI.GENERATE()                                      │                  │
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
│  6-1. 폴링 (2초 간격) — SELECT만 수행                                                    │
│  6-2. 결과 조회                                                                          │
│  6-3. CLOB 결과 반환 → AI 분석 리포트 출력                                                │
│       (Case 2와 동일 수준: Tuning Advisor 해석 + SQL Profile 적용성 평가 포함)            │
│                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Case 3 vs Case 4 비교

| 단계 | Case 3 (Standby) | Case 4 (ADG + Tuning) |
|------|------------------|----------------------|
| Step 1-0~1-4 | Standby 수집 | **동일** (DISPLAY_CURSOR, V$SQL_PLAN) |
| Step 1-5 | Tuning Advisor **스킵** | **ADG로 Primary에 위임** (database_link_to) |
| Step 2 | tuning_advice = 스킵 메시지 | tuning_advice = **DBMS_SQLTUNE 리포트** |
| Step 5 | Advisor 섹션 없음 | **Advisor 섹션 포함** (Case 2와 동일) |
| AI 분석 | 실행계획+통계만으로 분석 | **Oracle 진단 + AI 해석** 종합 |
| 추가 소요시간 | 없음 | **~30초** (Tuning Task 실행) |
| 라이선스 | EE 기본 | **Tuning Pack + Diagnostics Pack** |

---

## DB Link 구조 (Case 4)

```
                    ┌─────────────────────┐
                    │     Primary DB      │
                    │                     │
        ┌──────────│  (Tuning 분석 수행)  │
        │           │  (Task 데이터 저장)  │
        │           │  (SQL Profile 생성)  │
        │           └─────────────────────┘
        │                     ▲
        │ database_link_to    │ Redo Apply
        │ (LNK_TO_PRI)       │ (SQL Profile 전파)
        │ SYS$UMF             │
        │                     │
┌───────┴─────────────────────┴──────┐
│          DB1 (Standby / R-O)        │
│                                     │
│  analyze_query(                     │
│    p_primary_db_link => 'LNK_TO_PRI'│
│  )                                  │
│    │                                │
│    └─── ADB_LINK ──────────────────┼──────►  ADB
│         (일반 유저)                 │         (AI 분석)
└─────────────────────────────────────┘
```

---

## 사용하는 소스 파일

| 위치 | 파일 | 이 플로우에서의 역할 |
|------|------|-------------------|
| DB1 | `src/db1/query_analyzer_pkg.sql` | Step 1: `collect_query_info()` + **`get_tuning_advice_via_adg()`** |
| DB1 | `src/db1/analyze_query_func.sql` | Step 1~6: **`p_primary_db_link`** 파라미터로 ADG 경로 제어 |
| DB1 | `src/db1/test_adg_sqltune.py` | **Case 4 전용 5단계 테스트** |
| ADB | `src/adb/tables.sql` | Step 3: 요청/결과 테이블 (변경 없음) |
| ADB | `src/adb/ai_profile_setup.sql` | 사전 설정: Credential + AI Profile (변경 없음) |
| ADB | `src/adb/process_ai_analysis.sql` | Step 5: LLM 호출 — tuning_advice 있으면 프롬프트에 포함 (변경 없음) |
| ADB | `src/adb/scheduler_job.sql` | Step 4: Scheduler Job (변경 없음) |
