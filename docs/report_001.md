# Case 1: AI 직접 분석 — Query Analysis Report

> **케이스**: Case 1 (Tuning Pack 없이 AI 직접 분석)
> **Request ID**: 1 | **Source DB**: DB0225_PDB1 | **Requested By**: E2E_TEST
> **Status**: DONE | **요청 시각**: 2026-03-04 10:15:22.341028
> **분석 모델**: QUERY_ANALYZER_GROK4 (xai.grok-4) | **분석 소요**: 42.31초 | **결과 시각**: 2026-03-04 10:16:04.652781
> **사용 경로**: Primary 경로 (EXPLAIN PLAN) | **Tuning Pack**: 미사용

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

> **Case 1**: Tuning Pack 미사용 — 이 섹션은 비어 있습니다.

```
SQL Tuning Advisor 실행 실패: ORA-13616: 현재 사용자(SYSTEM)에게 ADVISOR 권한이 없거나
Tuning Pack 라이선스가 활성화되지 않았습니다.
```

---

## 6. AI 분석 결과 (Grok 4)

> **참고**: Tuning Advisor 결과 없이, 실행계획 + 통계 + 인덱스 정보만으로 분석한 결과입니다.

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
    - IX_SCHEDULE_AIRDT (on AIR_DATETIME): WHERE air_datetime >= 조건에 적합하나, Full Scan 선택됨.
    - UX_EPISODE_PROG_EP (on PROGRAM_ID, SEASON_NO, EPISODE_NO): 조인에 PROGRAM_ID 사용되나 HASH JOIN으로 인해 미사용.
    - 기타 PK 인덱스(SYS_C00xxxx): 조인 키지만 Full Scan 우선.

- **신규 인덱스 생성이 필요한 경우 DDL 제시**:
  - ENM_SCHEDULE 테이블의 WHERE 조건(channel, air_datetime)이 자주 사용되므로, 복합 인덱스 생성 추천:
    ```sql
    CREATE INDEX IX_SCHEDULE_CHANNEL_AIRDT ON ENM_SCHEDULE (CHANNEL, AIR_DATETIME);
    ```
  - 이유: CHANNEL + AIR_DATETIME 복합 조건에 최적. 범위 스캔과 필터링을 동시에 최적화. 기존 단일 컬럼 인덱스 2개보다 효율적.

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
  - 예상 효과: Full Scan 감소로 비용 9에서 5~7로 낮아질 수 있음.

### 5. SQL Tuning Advisor 결과 해석
- **Tuning Advisor 결과 없음**: Tuning Pack 라이선스가 없어 DBMS_SQLTUNE을 실행할 수 없었습니다. 위의 분석은 실행계획, 테이블 통계, 인덱스 정보만을 기반으로 수행되었습니다. Tuning Pack이 있다면 SQL Profile 권고, 대체 실행계획 비교, 실측 통계 기반 검증 등 추가 인사이트를 얻을 수 있습니다.

### 6. 추가 권고사항
- **통계 갱신 필요 여부**:
  - 현재 필요 없음. last_analyzed가 최근이며 num_rows와 distinct_keys가 정확히 반영됨. 데이터 변경 시 DBMS_STATS.GATHER_TABLE_STATS 실행 추천.

- **파티셔닝/파라미터 변경 등 구조적 개선 제안**:
  - 파티셔닝: 현재 불필요(1블록). 대규모 시 ENM_SCHEDULE를 air_datetime 기준 RANGE 파티셔닝 고려.
  - 파라미터 변경: OPTIMIZER_INDEX_COST_ADJ=50으로 설정해 인덱스 우선. 데이터가 작아 현재는 불필요.
  - Materialized View: 쿼리 빈도가 높으면 조인 결과를 캐싱하는 MV 생성 고려.
  - 히스토그램: IX_SCHEDULE_CHANNEL의 distinct_keys=1은 히스토그램이 없어 발생할 수 있음. DBMS_STATS로 히스토그램 수집 추천.
