# Case 2: 튜닝팩 사용 — Query Analysis Report

> **케이스**: Case 2 (Tuning Pack + AI 종합 분석)
> **Request ID**: 3 | **Source DB**: DB0225_PDB1 | **Requested By**: E2E_TUNE_V2
> **Status**: DONE | **요청 시각**: 2026-03-04 10:15:22.341028
> **분석 모델**: QUERY_ANALYZER_GROK4 (xai.grok-4) | **분석 소요**: 56.86초 | **결과 시각**: 2026-03-04 10:16:19.201453
> **사용 경로**: Primary 경로 (EXPLAIN PLAN + DBMS_SQLTUNE) | **Tuning Pack**: 사용

---

## 1. 분석 대상 SQL

```sql
SELECT p.program_title,
       s.air_datetime,
       s.tv_rating_pct,
       ad.ad_product,
       ad.impressions,
       ad.revenue_krw
FROM ENM_SCHEDULE s
JOIN ENM_EPISODE e ON s.episode_id = e.episode_id
JOIN ENM_PROGRAM p ON e.program_id = p.program_id
LEFT JOIN ENM_AD_DELIVERY ad ON s.schedule_id = ad.schedule_id
WHERE s.channel = 'tvN'
  AND s.air_datetime >= DATE '2025-01-01'
ORDER BY s.air_datetime
```

---

## 2. 실행계획 (DBMS_XPLAN.DISPLAY)

> **수집 방법**: `EXPLAIN PLAN FOR <SQL>` → `DBMS_XPLAN.DISPLAY('PLAN_TABLE', ...)`

```
Plan hash value: 1402197601

----------------------------------------------------------------------------------------------------------------
| Id  | Operation                               | Name                 | Rows  | Bytes | Cost (%CPU)| Time     |
----------------------------------------------------------------------------------------------------------------
|   0 | SELECT STATEMENT                        |                      |     3 |   201 |     9  (12)| 00:00:01 |
|   1 |  SORT ORDER BY                          |                      |     3 |   201 |     9  (12)| 00:00:01 |
|*  2 |   HASH JOIN                             |                      |     3 |   201 |     8   (0)| 00:00:01 |
|*  3 |    HASH JOIN                            |                      |     3 |   123 |     6   (0)| 00:00:01 |
|   4 |     NESTED LOOPS OUTER                  |                      |     3 |   105 |     4   (0)| 00:00:01 |
|*  5 |      TABLE ACCESS FULL                  | ENM_SCHEDULE         |     3 |    66 |     2   (0)| 00:00:01 |
|   6 |      TABLE ACCESS BY INDEX ROWID BATCHED| ENM_AD_DELIVERY      |     1 |    13 |     1   (0)| 00:00:01 |
|*  7 |       INDEX RANGE SCAN                  | IX_DELIVERY_SCHEDULE |     2 |       |     0   (0)| 00:00:01 |
|   8 |     TABLE ACCESS FULL                   | ENM_EPISODE          |     5 |    30 |     2   (0)| 00:00:01 |
|   9 |    TABLE ACCESS FULL                    | ENM_PROGRAM          |     4 |   104 |     2   (0)| 00:00:01 |
----------------------------------------------------------------------------------------------------------------

Predicate Information (identified by operation id):
---------------------------------------------------

   2 - access("E"."PROGRAM_ID"="P"."PROGRAM_ID")
   3 - access("S"."EPISODE_ID"="E"."EPISODE_ID")
   5 - filter("S"."CHANNEL"='tvN' AND "S"."AIR_DATETIME">=TO_DATE(' 2025-01-01 00:00:00', 'syyyy-mm-dd
              hh24:mi:ss'))
   7 - access("S"."SCHEDULE_ID"="AD"."SCHEDULE_ID"(+))

Column Projection Information (identified by operation id):
-----------------------------------------------------------

   1 - (#keys=1; rowset=256) "S"."AIR_DATETIME"[DATE,7], "P"."PROGRAM_TITLE"[VARCHAR2,200],
       "S"."TV_RATING_PCT"[NUMBER,22], "AD"."AD_PRODUCT"[VARCHAR2,50], "AD"."IMPRESSIONS"[NUMBER,22],
       "AD"."REVENUE_KRW"[NUMBER,22]
   2 - (#keys=1; rowset=256) "AD"."REVENUE_KRW"[NUMBER,22], "S"."AIR_DATETIME"[DATE,7],
       "S"."TV_RATING_PCT"[NUMBER,22], "AD"."AD_PRODUCT"[VARCHAR2,50], "AD"."IMPRESSIONS"[NUMBER,22],
       "P"."PROGRAM_TITLE"[VARCHAR2,200]
   3 - (#keys=1; rowset=256) "AD"."REVENUE_KRW"[NUMBER,22], "S"."AIR_DATETIME"[DATE,7],
       "S"."TV_RATING_PCT"[NUMBER,22], "AD"."AD_PRODUCT"[VARCHAR2,50], "AD"."IMPRESSIONS"[NUMBER,22],
       "E"."PROGRAM_ID"[NUMBER,22]
   4 - (#keys=0) "S"."EPISODE_ID"[NUMBER,22], "S"."AIR_DATETIME"[DATE,7],
       "S"."TV_RATING_PCT"[NUMBER,22], "AD"."AD_PRODUCT"[VARCHAR2,50], "AD"."IMPRESSIONS"[NUMBER,22],
       "AD"."REVENUE_KRW"[NUMBER,22]
   5 - "S"."SCHEDULE_ID"[NUMBER,22], "S"."EPISODE_ID"[NUMBER,22], "S"."AIR_DATETIME"[DATE,7],
       "S"."TV_RATING_PCT"[NUMBER,22]
   6 - "AD"."AD_PRODUCT"[VARCHAR2,50], "AD"."IMPRESSIONS"[NUMBER,22], "AD"."REVENUE_KRW"[NUMBER,22]
   7 - "AD".ROWID[ROWID,10]
   8 - (rowset=256) "E"."EPISODE_ID"[NUMBER,22], "E"."PROGRAM_ID"[NUMBER,22]
   9 - (rowset=256) "P"."PROGRAM_ID"[NUMBER,22], "P"."PROGRAM_TITLE"[VARCHAR2,200]
```

---

## 3. 테이블 통계

| 테이블 | 건수 | 블록 | 평균행길이 | 파티션 | 통계수집일 |
|--------|------|------|-----------|--------|------------|
| ENM_AD_DELIVERY | 3 | 1 | 19 | NO | 2026-02-25 06:00:08 |
| ENM_EPISODE | 5 | 1 | 39 | NO | 2026-02-25 06:00:08 |
| ENM_PROGRAM | 4 | 1 | 50 | NO | 2026-03-03 06:00:09 |
| ENM_SCHEDULE | 3 | 1 | 28 | NO | 2026-02-25 06:00:08 |

---

## 4. 인덱스 정보

| 인덱스명 | 테이블 | 컬럼 | 유일성 | 상태 | Distinct Keys |
|----------|--------|------|--------|------|---------------|
| IX_DELIVERY_CAMPAIGN | ENM_AD_DELIVERY | CAMPAIGN_ID | NONUNIQUE | VALID | 2 |
| IX_DELIVERY_SCHEDULE | ENM_AD_DELIVERY | SCHEDULE_ID | NONUNIQUE | VALID | 2 |
| SYS_C008227 | ENM_AD_DELIVERY | DELIVERY_ID | UNIQUE | VALID | 3 |
| SYS_C008201 | ENM_EPISODE | EPISODE_ID | UNIQUE | VALID | 5 |
| UX_EPISODE_PROG_EP | ENM_EPISODE | PROGRAM_ID, SEASON_NO, EPISODE_NO | UNIQUE | VALID | 5 |
| SYS_C008197 | ENM_PROGRAM | PROGRAM_ID | UNIQUE | VALID | 4 |
| IX_SCHEDULE_AIRDT | ENM_SCHEDULE | AIR_DATETIME | NONUNIQUE | VALID | 3 |
| IX_SCHEDULE_CHANNEL | ENM_SCHEDULE | CHANNEL | NONUNIQUE | VALID | 1 |
| SYS_C008207 | ENM_SCHEDULE | SCHEDULE_ID | UNIQUE | VALID | 3 |

---

## 5. Oracle SQL Tuning Advisor 결과

> **Case 2**: Tuning Pack 사용 — DBMS_SQLTUNE 실행 결과입니다.

```
GENERAL INFORMATION SECTION
-------------------------------------------------------------------------------
Tuning Task Name   : QA_TUNE_2026030410152358
Tuning Task Owner  : SYSTEM
Workload Type      : Single SQL Statement
Scope              : COMPREHENSIVE
Time Limit(seconds): 30
Completion Status  : COMPLETED
Started at         : 03/04/2026 10:15:23
Completed at       : 03/04/2026 10:15:24

-------------------------------------------------------------------------------
Schema Name   : SYSTEM
Container Name: DB0225_PDB1
SQL ID        : 0cw7jdzg1867c
SQL Text      : SELECT p.program_title, s.air_datetime, s.tv_rating_pct,
                ad.ad_product, ad.impressions, ad.revenue_krw FROM
                ENM_SCHEDULE s JOIN ENM_EPISODE e ON s.episode_id =
                e.episode_id JOIN ENM_PROGRAM p ON e.program_id =
                p.program_id LEFT JOIN ENM_AD_DELIVERY ad ON s.schedule_id =
                ad.schedule_id WHERE s.channel = 'tvN' AND s.air_datetime >=
                DATE '2025-01-01' ORDER BY s.air_datetime

-------------------------------------------------------------------------------
FINDINGS SECTION (1 finding)
-------------------------------------------------------------------------------

1- SQL Profile Finding (see explain plans section below)
--------------------------------------------------------
  A potentially better execution plan was found for this statement.

  Recommendation (estimated benefit: 11.15%)
  ------------------------------------------
  - Consider accepting the recommended SQL profile.
    execute dbms_sqltune.accept_sql_profile(task_name =>
            'QA_TUNE_2026030410152358', task_owner => 'SYSTEM', replace =>
            TRUE);

  Validation results
  ------------------
  The SQL profile was tested by executing both its plan and the original plan
  and measuring their respective execution statistics. A plan may have been
  only partially executed if the other could be run to completion in less time.

                           Original Plan  With SQL Profile  % Improved
                           -------------  ----------------  ----------
  Completion Status:            COMPLETE          COMPLETE
  Elapsed Time (s):             .000172           .000097       43.6 %
  CPU Time (s):                 .000154           .000097      37.01 %
  User I/O Time (s):            .000064                 0        100 %
  Buffer Gets:                        9                 8      11.11 %
  Physical Read Requests:             0                 0
  Physical Write Requests:            0                 0
  Physical Read Bytes:              819                 0        100 %
  Physical Write Bytes:               0                 0
  Rows Processed:                     4                 4
  Fetches:                            4                 4
  Executions:                         1                 1

  Notes
  -----
  1. Statistics for the original plan were averaged over 10 executions.
  2. Statistics for the SQL profile plan were averaged over 10 executions.

-------------------------------------------------------------------------------
EXPLAIN PLANS SECTION
-------------------------------------------------------------------------------

1- Original With Adjusted Cost
------------------------------
Plan hash value: 1402197601

----------------------------------------------------------------------------------------------------------------
| Id  | Operation                               | Name                 | Rows  | Bytes | Cost (%CPU)| Time     |
----------------------------------------------------------------------------------------------------------------
|   0 | SELECT STATEMENT                        |                      |     3 |   201 |     9  (12)| 00:00:01 |
|   1 |  SORT ORDER BY                          |                      |     3 |   201 |     9  (12)| 00:00:01 |
|*  2 |   HASH JOIN                             |                      |     3 |   201 |     8   (0)| 00:00:01 |
|*  3 |    HASH JOIN                            |                      |     3 |   123 |     6   (0)| 00:00:01 |
|   4 |     NESTED LOOPS OUTER                  |                      |     3 |   105 |     4   (0)| 00:00:01 |
|*  5 |      TABLE ACCESS FULL                  | ENM_SCHEDULE         |     3 |    66 |     2   (0)| 00:00:01 |
|   6 |      TABLE ACCESS BY INDEX ROWID BATCHED| ENM_AD_DELIVERY      |     1 |    13 |     1   (0)| 00:00:01 |
|*  7 |       INDEX RANGE SCAN                  | IX_DELIVERY_SCHEDULE |     2 |       |     0   (0)| 00:00:01 |
|   8 |     TABLE ACCESS FULL                   | ENM_EPISODE          |     5 |    30 |     2   (0)| 00:00:01 |
|   9 |    TABLE ACCESS FULL                    | ENM_PROGRAM          |     4 |   104 |     2   (0)| 00:00:01 |
----------------------------------------------------------------------------------------------------------------

Predicate Information (identified by operation id):
---------------------------------------------------

   2 - access("E"."PROGRAM_ID"="P"."PROGRAM_ID")
   3 - access("S"."EPISODE_ID"="E"."EPISODE_ID")
   5 - filter("S"."CHANNEL"='tvN' AND "S"."AIR_DATETIME">=TO_DATE(' 2025-01-01 00:00:00', 'syyyy-mm-dd
              hh24:mi:ss'))
   7 - access("S"."SCHEDULE_ID"="AD"."SCHEDULE_ID"(+))

2- Using SQL Profile
--------------------
Plan hash value: 2454072086

-------------------------------------------------------------------------------------
| Id  | Operation                       | Name              | Rows  | Bytes | Cost  |
-------------------------------------------------------------------------------------
|   0 | SELECT STATEMENT                |                   |     3 |   201 |    57 |
|   1 |  SORT ORDER BY                  |                   |     3 |   201 |    57 |
|*  2 |   HASH JOIN                     |                   |     3 |   201 |    10 |
|   3 |    MERGE JOIN CARTESIAN         |                   |    12 |   732 |     7 |
|*  4 |     HASH JOIN OUTER             |                   |     3 |   105 |     5 |
|*  5 |      TABLE ACCESS BY INDEX ROWID| ENM_SCHEDULE      |     3 |    66 |     2 |
|*  6 |       INDEX RANGE SCAN          | IX_SCHEDULE_AIRDT |     3 |       |     1 |
|   7 |      TABLE ACCESS FULL          | ENM_AD_DELIVERY   |     3 |    39 |     2 |
|   8 |     BUFFER SORT                 |                   |     4 |   104 |     5 |
|   9 |      TABLE ACCESS FULL          | ENM_PROGRAM       |     4 |   104 |     1 |
|  10 |    TABLE ACCESS FULL            | ENM_EPISODE       |     5 |    30 |     2 |
-------------------------------------------------------------------------------------

Predicate Information (identified by operation id):
---------------------------------------------------

   2 - access("E"."PROGRAM_ID"="P"."PROGRAM_ID" AND
              "S"."EPISODE_ID"="E"."EPISODE_ID")
   4 - access("S"."SCHEDULE_ID"="AD"."SCHEDULE_ID"(+))
   5 - filter("S"."CHANNEL"='tvN')
   6 - access("S"."AIR_DATETIME">=TO_DATE(' 2025-01-01 00:00:00',
              'syyyy-mm-dd hh24:mi:ss'))

-------------------------------------------------------------------------------
```

---

## 6. AI 분석 결과 (Grok 4)

> **참고**: 실행계획 + 통계 + 인덱스 + **Tuning Advisor 결과**를 모두 종합하여 분석한 결과입니다.

### 1. 실행계획 요약
- **전체 실행 흐름 단계별 설명**:
  - Operation Id 5: ENM_SCHEDULE 테이블에 대한 TABLE ACCESS FULL (전체 테이블 스캔)으로 시작. WHERE 조건(s.channel = 'tvN' AND s.air_datetime >= DATE '2025-01-01')을 필터링하며, 예상 3행을 추출.
  - Operation Id 4-7: NESTED LOOPS OUTER 조인을 통해 ENM_AD_DELIVERY 테이블과 LEFT JOIN. ENM_SCHEDULE의 각 행에 대해 IX_DELIVERY_SCHEDULE 인덱스를 사용한 INDEX RANGE SCAN (Id 7)으로 ENM_AD_DELIVERY를 액세스하고, 필요 시 TABLE ACCESS BY INDEX ROWID BATCHED (Id 6)로 데이터 가져옴.
  - Operation Id 3-8: 위 결과와 ENM_EPISODE 테이블을 HASH JOIN (access: s.episode_id = e.episode_id). ENM_EPISODE는 TABLE ACCESS FULL로 처리.
  - Operation Id 2-9: 위 결과와 ENM_PROGRAM 테이블을 HASH JOIN (access: e.program_id = p.program_id). ENM_PROGRAM은 TABLE ACCESS FULL로 처리.
  - Operation Id 1: 전체 결과를 s.air_datetime 기준으로 SORT ORDER BY 정렬.
  - Operation Id 0: 최종 SELECT STATEMENT로 결과 반환.

- **예상 비용(Cost)과 카디널리티(Rows) 해석**:
  - 전체 Cost: 9 (CPU 12%), 매우 낮음. 테이블 크기가 작아(각 테이블 3~5행, 1블록) 비용이 최소화됨. 실제 대규모 데이터셋에서는 비용이 증가할 수 있음.
  - Rows: 대부분 3~5행으로 추정. 카디널리티가 정확함(ENM_SCHEDULE 필터 후 3행, 조인 후 3행). 옵티마이저가 통계 기반으로 정확히 예측 중.

### 2. 성능 병목 분석
- **Full Table Scan이 발생하는 구간과 원인**:
  - ENM_SCHEDULE (Id 5): WHERE 조건(channel = 'tvN' AND air_datetime >= '2025-01-01')에도 불구하고 Full Table Scan. 원인: channel에 인덱스(IX_SCHEDULE_CHANNEL)가 있지만 distinct_keys=1로 선택도가 낮아(모든 행이 'tvN'일 가능성), 옵티마이저가 Full Scan 선택. air_datetime 인덱스(IX_SCHEDULE_AIRDT)는 사용되지 않음(조건이 >= 범위 스캔에 적합하지만, channel과 결합되지 않아 무시됨).
  - ENM_EPISODE (Id 8)와 ENM_PROGRAM (Id 9): HASH JOIN 시 Full Table Scan. 원인: 조인 키(episode_id, program_id)에 적합한 인덱스가 있지만, HASH JOIN 특성상 Full Scan이 선호됨. 테이블이 작아 인덱스 사용 이점이 적음.
  - 병목 정도: 데이터가 작아(총 3~5행) 실제 병목 없음. 대규모 데이터에서는 Full Scan이 I/O 비용 증가시킴.

- **비효율적인 조인 방식 식별**:
  - HASH JOIN (Id 2, 3): 작은 테이블에서 효율적이나, ENM_EPISODE와 ENM_PROGRAM이 Full Scan으로 인해 메모리 해싱 비용 발생. NESTED LOOPS가 더 나을 수 있음(행 수가 적음).
  - NESTED LOOPS OUTER (Id 4): 적절하나, 외부 조인으로 인해 불필요한 반복 액세스 가능성 있음.

- **불필요한 Sort/Hash 연산 확인**:
  - SORT ORDER BY (Id 1): ORDER BY air_datetime으로 인해 발생. 데이터가 작아 비용 낮음(Cost 9 중 1), 하지만 대규모 시 메모리/임시 공간 사용.
  - HASH 연산 (Id 2, 3): 작은 데이터셋에서 불필요할 수 있음. MERGE JOIN으로 대체 가능.

### 3. 인덱스 활용도 평가
- **현재 사용되는 인덱스와 미사용 인덱스**:
  - 사용: IX_DELIVERY_SCHEDULE (on SCHEDULE_ID) – LEFT JOIN 시 INDEX RANGE SCAN (Id 7)으로 활용. 선택도가 높아 효과적.
  - 미사용:
    - IX_SCHEDULE_CHANNEL (on CHANNEL): WHERE channel = 'tvN' 조건에 적합하나, distinct_keys=1로 선택도 낮아 무시됨.
    - IX_SCHEDULE_AIRDT (on AIR_DATETIME): WHERE air_datetime >= 조건에 적합하나, Full Scan 선택됨. **단, Tuning Advisor가 제안한 SQL Profile 플랜에서는 이 인덱스가 활용됨** (아래 참고).
    - UX_EPISODE_PROG_EP (on PROGRAM_ID, SEASON_NO, EPISODE_NO): 조인에 PROGRAM_ID 사용되나 HASH JOIN으로 인해 미사용.
    - 기타 PK 인덱스(SYS_C00xxxx): 조인 키지만 Full Scan 우선.

- **신규 인덱스 생성이 필요한 경우 DDL 제시**:
  - ENM_SCHEDULE 테이블의 WHERE 조건(channel, air_datetime)이 자주 사용되므로, 복합 인덱스 생성 추천:
    ```sql
    CREATE INDEX IX_SCHEDULE_CHANNEL_AIRDT ON ENM_SCHEDULE (CHANNEL, AIR_DATETIME);
    ```
  - 이유: CHANNEL + AIR_DATETIME 복합 조건에 최적. Tuning Advisor의 SQL Profile은 기존 IX_SCHEDULE_AIRDT 단일 인덱스를 활용하지만, 복합 인덱스가 CHANNEL 필터까지 포함하여 더 효율적.

### 4. 최적화된 SQL
- **개선된 SQL문 제시 (힌트 포함)**:
  ```sql
  SELECT /*+ LEADING(s) USE_NL(e p) INDEX(s IX_SCHEDULE_CHANNEL_AIRDT) */
         p.program_title, s.air_datetime, s.tv_rating_pct,
         ad.ad_product, ad.impressions, ad.revenue_krw
  FROM ENM_SCHEDULE s
  JOIN ENM_EPISODE e ON s.episode_id = e.episode_id
  JOIN ENM_PROGRAM p ON e.program_id = p.program_id
  LEFT JOIN ENM_AD_DELIVERY ad ON s.schedule_id = ad.schedule_id
  WHERE s.channel = 'tvN' AND s.air_datetime >= DATE '2025-01-01'
  ORDER BY s.air_datetime;
  ```

- **변경 사유 설명**:
  - LEADING(s): ENM_SCHEDULE를 드라이빙 테이블로 지정, 필터 조건이 많아 최적.
  - USE_NL(e p): HASH JOIN 대신 NESTED LOOPS로 변경. 작은 행 수에서 효율적.
  - INDEX(s IX_SCHEDULE_CHANNEL_AIRDT): 신규 복합 인덱스 사용 강제. Full Scan을 INDEX RANGE SCAN으로 대체.
  - 예상 효과: Full Scan 감소로 비용 9에서 5~7로 낮아질 수 있음. Tuning Advisor의 SQL Profile 플랜(Cost 57, 실제 43.6% 빠름)보다 더 효율적일 수 있음.

### 5. SQL Tuning Advisor 결과 해석
- **Oracle이 제안한 SQL Profile, 인덱스, 대체 SQL 등의 권고 해석**:
  - SQL Profile 추천: 원본 플랜(Cost 9, Plan hash 1402197601) 대신 새로운 플랜(Cost 57, Plan hash 2454072086)을 사용. 새로운 플랜은 INDEX RANGE SCAN on IX_SCHEDULE_AIRDT (Id 6)로 ENM_SCHEDULE에 접근, HASH JOIN OUTER로 ENM_AD_DELIVERY와 조인, MERGE JOIN CARTESIAN으로 ENM_PROGRAM 추가, 최종 HASH JOIN으로 ENM_EPISODE 조인. 이는 air_datetime 조건을 인덱스로 활용해 Full Scan을 피함.
  - 인덱스/대체 SQL: 별도 인덱스 추천 없음(기존 IX_SCHEDULE_AIRDT 활용). 대체 플랜은 MERGE JOIN CARTESIAN 사용(작은 테이블 간 카테시안 곱 후 조인, 데이터 작아 효율적).
  - 테스트 결과: **Buffer Gets 11.11% 개선, Elapsed Time 43.6% 감소, Physical Read 100% 감소**(인덱스 활용으로).

- **Tuning Advisor 권고의 적용 가능성과 예상 효과 평가**:
  - 적용 가능성: 높음. `dbms_sqltune.accept_sql_profile(...)` 실행으로 즉시 적용 가능. 데이터가 작아(Rows 3~5) 실제 효과 미미하나, 스케일업 시(예: 수만 행) Full Scan 피함으로 I/O/시간 대폭 개선.
  - 예상 효과: 11.15% 전체 개선(테스트 기반). Buffer Gets 감소로 메모리 효율 ↑, Physical Read 0으로 디스크 I/O 최소화. Cost가 9에서 57로 증가하지만 이는 추정치 오류(작은 데이터셋에서 발생); **실측 통계(Elapsed Time 43.6% ↓)가 더 신뢰할 만함.**

- **Advisor 권고가 없는 경우 그 이유 분석**:
  - Advisor가 SQL Profile만 추천(인덱스/구조 변경 없음). 이유: 테이블이 극히 작아(1블록, 3~5행) 추가 인덱스나 리팩토링 이점이 적음. 통계가 최신이고, 기존 인덱스(IX_SCHEDULE_AIRDT)로 충분. 대규모 데이터였다면 더 많은 권고(인덱스 생성 등) 나올 수 있음.

### 6. 추가 권고사항
- **통계 갱신 필요 여부**:
  - 현재 필요 없음. last_analyzed가 최근이며 num_rows와 distinct_keys가 정확히 반영됨. 데이터 변경 시 DBMS_STATS.GATHER_TABLE_STATS 실행 추천.

- **파티셔닝/파라미터 변경 등 구조적 개선 제안**:
  - 파티셔닝: 현재 불필요(1블록). 대규모 시 ENM_SCHEDULE를 air_datetime 기준 RANGE 파티셔닝 고려.
  - 파라미터 변경: OPTIMIZER_INDEX_COST_ADJ=50으로 설정해 인덱스 우선. 데이터가 작아 현재는 불필요.
  - SQL Profile 적용: Tuning Advisor가 제안한 SQL Profile을 적용하면 즉시 효과를 볼 수 있음. 단, 복합 인덱스(IX_SCHEDULE_CHANNEL_AIRDT) 생성 후에는 SQL Profile보다 더 나은 플랜이 나올 수 있으므로, 인덱스 생성 후 재평가 필요.
  - 히스토그램: IX_SCHEDULE_CHANNEL의 distinct_keys=1은 히스토그램이 없어 발생할 수 있음. DBMS_STATS로 히스토그램 수집 추천.
