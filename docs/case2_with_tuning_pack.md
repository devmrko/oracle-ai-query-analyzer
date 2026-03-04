# Case 2: 튜닝팩 사용 (SQL Tuning Advisor + AI 종합 분석)

> **적용 대상**: Oracle Tuning Pack 라이선스가 있는 Primary DB 환경
> **샘플 결과**: [report_002.md](report_002.md)

---

## 1. 개요

Oracle SQL Tuning Advisor(`DBMS_SQLTUNE`)의 분석 결과까지 수집하여 AI에 전달하는 모드입니다.

AI는 **실행계획 + 테이블 통계 + 인덱스 정보 + Tuning Advisor 결과**를 모두 종합하여, Oracle 자체 진단 결과를 해석하고 추가적인 최적화 방안까지 제시합니다.

```
┌─────────────────────────┐        DB Link        ┌──────────────────────┐
│        DB1 (Primary)     │ ───────────────────── │     ADB              │
│                          │                        │                      │
│  수집 항목:              │   INSERT 요청          │  처리:               │
│  1. EXPLAIN PLAN 실행계획 │ ──────────────────►   │  1. 요청 저장        │
│  2. 테이블 통계 (JSON)   │                        │  2. LLM 프롬프트 구성│
│  3. 인덱스 정보 (JSON)   │   SELECT 결과          │  3. AI 분석 실행     │
│  4. DBMS_SQLTUNE 결과 ★ │ ◄──────────────────    │  4. 결과 저장        │
│                          │                        │                      │
│  ★ Tuning Pack 필요     │                        │                      │
└─────────────────────────┘                        └──────────────────────┘
```

### Case 1과의 차이점

| 항목 | Case 1 (AI 직접분석) | Case 2 (튜닝팩 사용) |
|------|---------------------|---------------------|
| Tuning Pack 라이선스 | 불필요 | **필요** |
| SQL Tuning Advisor | 미사용 (실패 메시지) | **DBMS_SQLTUNE 실행** |
| AI 프롬프트 | 4개 섹션 (SQL, 실행계획, 통계, 인덱스) | **5개 섹션** (+Tuning Advisor 결과) |
| AI 분석 '5. Tuning Advisor 해석' | AI가 자체 판단 | **Oracle 권고를 해석하고 평가** |
| SQL Profile 제안 | 없음 | Oracle이 SQL Profile 제안 가능 |
| 분석 정확도 | AI 자체 분석 | **Oracle 진단 + AI 해석** (더 정확) |

### AI가 추가로 분석하는 항목 (Case 2 전용)

| 번호 | 분석 항목 | 설명 |
|------|----------|------|
| 5 | SQL Tuning Advisor 결과 해석 | Oracle이 제안한 SQL Profile, 대체 실행계획의 적용 가능성/효과 평가 |

---

## 2. 사용하는 소스 파일

Case 1과 동일한 파일을 사용합니다. **추가 배포 필요 없음.**

### DB1 배포 파일

| 파일 | 용도 | Case 2에서의 역할 |
|------|------|------------------|
| `src/db1/query_analyzer_pkg.sql` | 핵심 패키지 | `collect_query_info()`에서 `DBMS_SQLTUNE` 자동 호출 |
| `src/db1/analyze_query_func.sql` | 래퍼 함수 | `tuning_advice` 필드를 ADB에 전달 |

### ADB 배포 파일

| 파일 | 용도 | Case 2에서의 역할 |
|------|------|------------------|
| `src/adb/tables.sql` | 요청/결과 테이블 | `ai_analysis_request.tuning_advice` 컬럼에 Advisor 결과 저장 |
| `src/adb/ai_profile_setup.sql` | LLM 프로파일 설정 | 동일 |
| `src/adb/process_ai_analysis.sql` | AI 프로세서 | `build_prompt()`에서 `tuning_advice`가 있으면 프롬프트에 추가 |
| `src/adb/scheduler_job.sql` | 스케줄러 Job | 동일 |

### 테스트

| 파일 | 용도 |
|------|------|
| `src/db1/test_connection.py` | 배포 및 기능 테스트 |
| `src/db1/test_sqltune.py` | **DBMS_SQLTUNE 권한 확인 테스트** — Case 2 사전 검증용 |
| `src/generate_report.py` | Markdown 리포트 생성 |

---

## 3. 사전 검증: Tuning Pack 사용 가능 여부

배포 전에 `test_sqltune.py`로 DBMS_SQLTUNE 권한을 확인합니다:

```bash
cd src/db1
python test_sqltune.py
```

이 스크립트는:
1. DBMS_SQLTUNE.CREATE_TUNING_TASK 호출 테스트
2. Task 실행 및 리포트 생성 확인
3. 성공 시 → Tuning Pack 사용 가능 (Case 2 적용 가능)
4. 실패 시 → Tuning Pack 라이선스 없음 (Case 1로 사용)

---

## 4. 배포 순서

Case 1과 완전히 동일합니다. 별도의 설정이 필요 없습니다.

> **핵심:** 코드 레벨에서 Case 1과 Case 2의 차이는 없습니다.
> `collect_query_info()`는 항상 Tuning Advisor를 호출 시도하고,
> 성공하면 결과를 포함하고(Case 2), 실패하면 에러 메시지를 포함합니다(Case 1).
> AI 프로세서는 `tuning_advice` 필드가 있으면 자동으로 프롬프트에 추가합니다.

배포 절차: [Case 1 배포 순서](case1_ai_direct_analysis.md#3-배포-순서) 참고.

---

## 5. 사용 방법

Case 1과 동일한 호출 방법을 사용합니다:

```sql
-- DB1에서 실행 (Tuning Pack이 있으면 자동으로 Advisor 결과 포함)
SELECT analyze_query('SELECT * FROM orders WHERE order_date > SYSDATE - 30')
FROM DUAL;
```

### 내부 동작 차이

```
analyze_query() 호출
    │
    ├── 1. query_analyzer.collect_query_info() 호출
    │       ├── EXPLAIN PLAN 실행 → 실행계획 추출
    │       ├── PLAN_TABLE에서 참조 테이블 추출
    │       ├── ALL_TABLES에서 테이블 통계 수집 (JSON)
    │       ├── ALL_INDEXES에서 인덱스 정보 수집 (JSON)
    │       └── DBMS_SQLTUNE 호출 ★
    │             ├── CREATE_TUNING_TASK → EXECUTE → REPORT
    │             ├── 성공: tuning_advice에 전체 리포트 저장
    │             └── 실패: "SQL Tuning Advisor 실행 실패: ..." 저장
    │
    ├── 2. ADB에 INSERT (DB Link) — tuning_advice 포함
    │
    ├── 3. ADB AI 프로세서:
    │       └── build_prompt()에서 tuning_advice 존재 확인
    │             ├── 있으면: "## Oracle SQL Tuning Advisor 결과" 섹션 추가 ★
    │             └── 없으면: 섹션 생략
    │
    └── 4. AI 분석 → 결과 반환
```

---

## 6. 주요 소스 코드 상세 (Case 2 관련 부분)

### `query_analyzer_pkg.sql` — Tuning Advisor 호출 부분

`collect_query_info()` 함수의 Primary 경로 6단계:

```sql
-- 6) SQL Tuning Advisor 실행
DECLARE
    v_tune_task  VARCHAR2(128);
    v_tune_gen   VARCHAR2(128);
    v_sql_vc     VARCHAR2(32767);
BEGIN
    v_tune_gen := 'QA_TUNE_' || TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISSFF2');
    v_sql_vc   := DBMS_LOB.SUBSTR(p_sql_text, 32767, 1);

    v_tune_task := DBMS_SQLTUNE.CREATE_TUNING_TASK(
        sql_text   => v_sql_vc,
        time_limit => 30,
        task_name  => v_tune_gen
    );
    DBMS_SQLTUNE.EXECUTE_TUNING_TASK(task_name => v_tune_task);
    v_result.tuning_advice := DBMS_SQLTUNE.REPORT_TUNING_TASK(task_name => v_tune_task);
    ...
EXCEPTION
    WHEN OTHERS THEN
        v_result.tuning_advice := 'SQL Tuning Advisor 실행 실패: ' || SQLERRM;
        ...
END;
```

**동작 방식:**
1. 고유한 Task 이름 생성 (`QA_TUNE_<타임스탬프>`)
2. `CREATE_TUNING_TASK`로 분석 작업 등록
3. `EXECUTE_TUNING_TASK`로 분석 실행 (최대 30초)
4. `REPORT_TUNING_TASK`로 리포트 추출 → `tuning_advice`에 저장
5. Task 정리 (`DROP_TUNING_TASK`)
6. **실패 시**: 에러 메시지를 `tuning_advice`에 저장 (전체 프로세스는 중단하지 않음)

### `process_ai_analysis.sql` — 프롬프트에 Tuning Advisor 결과 포함

`build_prompt()` 함수에서 `tuning_advice`가 있으면 자동 추가:

```sql
-- SQL Tuning Advisor 결과
IF p_tuning_advice IS NOT NULL AND DBMS_LOB.GETLENGTH(p_tuning_advice) > 0 THEN
    DBMS_LOB.APPEND(v_prompt,
        '## Oracle SQL Tuning Advisor 결과 (DBMS_SQLTUNE)' || CHR(10) ||
        '```' || CHR(10));
    DBMS_LOB.APPEND(v_prompt, p_tuning_advice);
    DBMS_LOB.APPEND(v_prompt,
        CHR(10) || '```' || CHR(10) || CHR(10));
END IF;
```

---

## 7. Tuning Advisor가 제공하는 정보

report_002.md의 실제 결과를 기반으로 정리하면:

### Oracle이 제공하는 Findings

| 항목 | 내용 | 예시 |
|------|------|------|
| SQL Profile | 더 나은 실행 플랜 발견 시 권고 | "estimated benefit: 11.15%" |
| 대체 실행계획 | Original vs Recommended 비교 | Cost 9 → 57 (하지만 실제 43.6% 빠름) |
| 실행 통계 비교 | Elapsed Time, CPU, Buffer Gets 등 | Buffer Gets: 9→8 (11.11% 감소) |
| SQL Profile 적용 명령 | 즉시 적용 가능한 PL/SQL | `dbms_sqltune.accept_sql_profile(...)` |

### AI가 해석하여 추가하는 가치

| AI 분석 항목 | 설명 |
|-------------|------|
| Cost vs 실제 성능 괴리 해석 | "Cost 57로 증가하지만 실제 43.6% 빠름 — 추정치 오류" |
| SQL Profile 적용 리스크 평가 | 적용 가능성, 부작용, 데이터 규모별 효과 예측 |
| Advisor 권고 없는 이유 분석 | "테이블이 소규모라 추가 최적화 이점 적음" |
| 추가 최적화 제안 | Advisor가 제안하지 않은 인덱스, 힌트 등 보완 |

---

## 8. 샘플 결과

[report_002.md](report_002.md) 참고. 주요 특징:

- **분석 대상**: 4개 테이블 JOIN (ENM_SCHEDULE, ENM_EPISODE, ENM_PROGRAM, ENM_AD_DELIVERY)
- **실행계획**: Cost 9, NESTED LOOPS OUTER + HASH JOIN
- **Tuning Advisor 결과**:
  - SQL Profile 권고 (11.15% 개선)
  - 대체 실행계획 제시 (INDEX RANGE SCAN 활용)
  - 검증 결과: Elapsed Time 43.6% 감소, Buffer Gets 11.11% 감소
- **AI 분석 결과**:
  - Advisor 결과를 해석하여 SQL Profile 적용 권고
  - 추가 복합 인덱스 DDL 제시: `CREATE INDEX IX_SCHEDULE_CHANNEL_AIRDT ON ENM_SCHEDULE (CHANNEL, AIR_DATETIME)`
  - Advisor가 제안하지 않은 NESTED LOOPS 힌트 추가 제안

---

## 9. 사전 조건

| 항목 | 요구사항 |
|------|---------|
| DB1 권한 | `CREATE PROCEDURE`, `EXPLAIN ANY`, 대상 테이블 `SELECT` |
| DB1 → ADB | DB Link 생성 |
| ADB 권한 | `DBMS_CLOUD_AI` 실행, 테이블 생성 |
| LLM 프로파일 | ADB에 AI 프로파일 설정 완료 |
| Oracle 라이선스 | **Tuning Pack 필요** — `DBMS_SQLTUNE` 사용 |
| DBMS_SQLTUNE 권한 | `ADVISOR` 권한 또는 DBA 역할 |
