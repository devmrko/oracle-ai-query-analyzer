# Case 3: Standby DB — Query Analysis Report

> **케이스**: Case 3 (Standby DB, Read-Only 환경)
> **Request ID**: 5 | **Source DB**: DB0225_PDB1 (Standby 경로 강제) | **Requested By**: E2E_STANDBY
> **Status**: DONE | **요청 시각**: 2026-03-04 10:15:22.341028
> **분석 모델**: QUERY_ANALYZER_GROK4 (xai.grok-4) | **분석 소요**: 39.74초 | **결과 시각**: 2026-03-04 10:16:02.085302
> **사용 경로**: Standby 경로 (DISPLAY_CURSOR) | **Tuning Pack**: 사용 불가 (Read-Only)
> **SQL_ID**: 0cw7jdzg1867c | **Child Number**: 0

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

## 2. 실행계획 (DBMS_XPLAN.DISPLAY_CURSOR)

> **수집 방법**: SQL 실행 → Shared Pool 캐싱 → `find_sql_id()` → `DBMS_XPLAN.DISPLAY_CURSOR(sql_id, child_number)`
> **Case 1/2와의 차이**: PLAN_TABLE에 INSERT하지 않고 V$SQL_PLAN 메모리 뷰에서 읽기만 수행

```
SQL_ID  0cw7jdzg1867c, child number 0
-------------------------------------
SELECT p.program_title, s.air_datetime, s.tv_rating_pct, ad.ad_product,
ad.impressions, ad.revenue_krw FROM ENM_SCHEDULE s JOIN ENM_EPISODE e
ON s.episode_id = e.episode_id JOIN ENM_PROGRAM p ON e.program_id =
p.program_id LEFT JOIN ENM_AD_DELIVERY ad ON s.schedule_id =
ad.schedule_id WHERE s.channel = 'tvN' AND s.air_datetime >= DATE
'2025-01-01' ORDER BY s.air_datetime

Plan hash value: 1402197601

----------------------------------------------------------------------------------------------------------------
| Id  | Operation                               | Name                 | Rows  | Bytes | Cost (%CPU)| Time     |
----------------------------------------------------------------------------------------------------------------
|   0 | SELECT STATEMENT                        |                      |       |       |     9 (100)|          |
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

Query Block Name / Object Alias (identified by operation id):
-------------------------------------------------------------

   1 - SEL$8E99DF4F
   5 - SEL$8E99DF4F / S@SEL$1
   6 - SEL$8E99DF4F / AD@SEL$3
   7 - SEL$8E99DF4F / AD@SEL$3
   8 - SEL$8E99DF4F / E@SEL$1
   9 - SEL$8E99DF4F / P@SEL$2

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

> **Case 3**: Standby DB — Tuning Advisor 실행 불가 (Read-Only 환경)

```
[Standby DB] SQL Tuning Advisor는 Read-Only 환경에서 실행할 수 없습니다.
Primary DB에서 analyze_query를 실행하면 튜닝 조언을 받을 수 있습니다.
(사용된 SQL_ID: 0cw7jdzg1867c)
```

---

## 6. AI 분석 결과 (Grok 4)

> **참고**: Standby DB에서 수집한 데이터입니다. 실행계획은 DISPLAY_CURSOR로 추출, Tuning Advisor는 스킵. 실행계획 + 통계 + 인덱스 정보만으로 분석한 결과입니다.

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
  - Rows: 대부분 3~5행으로 추정. 카디널리티가 정확함. DISPLAY_CURSOR에서 SELECT STATEMENT의 Rows가 공백인 것은 정상 — 커서 기반 추출 시 최상위 노드에 추정치가 표시되지 않을 수 있음.

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
  - **주의**: 인덱스 생성은 **Primary DB에서** 실행해야 합니다. Standby DB에서는 DDL 실행이 불가능합니다.

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
- **Tuning Advisor 결과 없음 (Standby 제약)**: Standby DB는 Read-Only 모드로 운영되어 DBMS_SQLTUNE 실행이 불가능합니다. Tuning Advisor는 내부적으로 Task 생성/실행 시 딕셔너리에 INSERT가 필요하기 때문입니다.
- **대안**: 동일 SQL을 Primary DB에서 `analyze_query()`로 실행하면 SQL Profile 권고 등 Tuning Advisor의 추가 인사이트를 얻을 수 있습니다. 또는 AWR 리포트에서 느린 SQL을 찾아 Primary에서 분석할 수 있습니다.

### 6. 추가 권고사항
- **통계 갱신 필요 여부**:
  - 현재 필요 없음. last_analyzed가 최근이며 num_rows와 distinct_keys가 정확히 반영됨. 통계 갱신은 **Primary DB에서** 실행해야 합니다 (Standby에서 DDL/DML 불가).

- **파티셔닝/파라미터 변경 등 구조적 개선 제안**:
  - 파티셔닝: 현재 불필요(1블록). 대규모 시 ENM_SCHEDULE를 air_datetime 기준 RANGE 파티셔닝 고려. Primary에서 적용.
  - 파라미터 변경: OPTIMIZER_INDEX_COST_ADJ=50으로 설정해 인덱스 우선. Primary에서 설정하면 Standby에도 반영됨.
  - Materialized View: Standby에서 생성 불가. Primary에서 MV 생성 후 Standby에 복제.
  - **Standby 특화 권고**: Standby에서 자주 실행되는 쿼리는 V$SQL에서 SQL_ID를 미리 확인해 두면 분석 속도가 빨라집니다 (`p_sql_id` 파라미터 지정).
