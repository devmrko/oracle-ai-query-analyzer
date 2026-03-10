# Oracle 내부 딕셔너리 조회 가이드

> SQL 분석에 필요한 테이블 메타데이터(테이블 정보, 컬럼 정보, 커멘트)를 Oracle 딕셔너리 뷰에서 조회하는 방법.

---

## 1. 딕셔너리 뷰 접두어

| 접두어 | 범위 | 설명 |
|--------|------|------|
| `USER_` | 현재 유저 소유 | 자기 스키마 객체만 |
| `ALL_` | 접근 가능한 전체 | 권한이 있는 모든 스키마 (권장) |
| `DBA_` | DB 전체 | DBA 권한 필요 |

> 이 프로젝트에서는 `ALL_` 뷰를 사용합니다. 다른 스키마 테이블도 분석 대상이 될 수 있기 때문.

---

## 2. 테이블 정보

### 2.1 ALL_TABLES — 테이블 기본 정보 + 통계

```sql
SELECT owner,
       table_name,
       num_rows,
       blocks,
       avg_row_len,
       TO_CHAR(last_analyzed, 'YYYY-MM-DD HH24:MI:SS') AS last_analyzed,
       degree,
       partitioned,
       temporary,
       tablespace_name,
       compression,
       row_movement
FROM all_tables
WHERE owner = :schema
  AND table_name = :table_name;
```

| 컬럼 | 설명 | 분석 활용 |
|------|------|----------|
| `NUM_ROWS` | 테이블 행 수 (통계 기준) | 카디널리티 판단 |
| `BLOCKS` | 사용 블록 수 | I/O 비용 추정 |
| `AVG_ROW_LEN` | 평균 행 길이(바이트) | Full Scan 비용 추정 |
| `LAST_ANALYZED` | 통계 수집일 | 통계 최신성 판단 |
| `DEGREE` | 병렬도 | Parallel Query 설정 |
| `PARTITIONED` | 파티셔닝 여부 | Partition Pruning 가능성 |
| `TEMPORARY` | 임시 테이블 여부 | GTT는 통계가 부정확할 수 있음 |

### 2.2 ALL_TAB_COMMENTS — 테이블 커멘트

```sql
SELECT owner,
       table_name,
       table_type,
       comments
FROM all_tab_comments
WHERE owner = :schema
  AND table_name = :table_name;
```

| 컬럼 | 설명 |
|------|------|
| `TABLE_TYPE` | `TABLE`, `VIEW`, `SYNONYM` 등 |
| `COMMENTS` | `COMMENT ON TABLE` 으로 등록한 설명 |

### 2.3 특정 스키마의 전체 테이블 + 커멘트

```sql
SELECT t.owner,
       t.table_name,
       t.num_rows,
       t.blocks,
       t.partitioned,
       c.comments AS table_comment
FROM all_tables t
LEFT JOIN all_tab_comments c
    ON c.owner = t.owner AND c.table_name = t.table_name
WHERE t.owner = :schema
ORDER BY t.table_name;
```

---

## 3. 컬럼 정보

### 3.1 ALL_TAB_COLUMNS — 컬럼 상세

```sql
SELECT owner,
       table_name,
       column_name,
       column_id,
       data_type,
       data_length,
       data_precision,
       data_scale,
       nullable,
       num_distinct,
       num_nulls,
       density,
       low_value,
       high_value,
       histogram,
       TO_CHAR(last_analyzed, 'YYYY-MM-DD HH24:MI:SS') AS last_analyzed
FROM all_tab_columns
WHERE owner = :schema
  AND table_name = :table_name
ORDER BY column_id;
```

| 컬럼 | 설명 | 분석 활용 |
|------|------|----------|
| `DATA_TYPE` | VARCHAR2, NUMBER, DATE 등 | 타입 변환 비용, 인덱스 적합성 |
| `NULLABLE` | NULL 허용 여부 | IS NULL 조건 최적화 |
| `NUM_DISTINCT` | 고유값 수 | 선택도(Selectivity) 계산 |
| `NUM_NULLS` | NULL 건수 | NULL 비율 = NUM_NULLS / NUM_ROWS |
| `DENSITY` | 선택도 밀도 | 옵티마이저 카디널리티 추정 핵심 |
| `LOW_VALUE` / `HIGH_VALUE` | 최소/최대값 (RAW) | 범위 조건 카디널리티 추정 |
| `HISTOGRAM` | 히스토그램 유형 | NONE, FREQUENCY, HEIGHT BALANCED, HYBRID, TOP-FREQUENCY |

### 3.2 LOW_VALUE / HIGH_VALUE 사람이 읽을 수 있는 값으로 변환

```sql
-- NUMBER 타입인 경우
SELECT column_name,
       UTL_RAW.CAST_TO_NUMBER(low_value)  AS low_val,
       UTL_RAW.CAST_TO_NUMBER(high_value) AS high_val
FROM all_tab_columns
WHERE owner = :schema
  AND table_name = :table_name
  AND data_type = 'NUMBER';

-- VARCHAR2 타입인 경우
SELECT column_name,
       UTL_RAW.CAST_TO_VARCHAR2(low_value)  AS low_val,
       UTL_RAW.CAST_TO_VARCHAR2(high_value) AS high_val
FROM all_tab_columns
WHERE owner = :schema
  AND table_name = :table_name
  AND data_type LIKE '%CHAR%';

-- DATE 타입인 경우
SELECT column_name,
       TO_CHAR(
           TO_DATE(
               TO_CHAR(100 * (TO_NUMBER(SUBSTR(RAWTOHEX(low_value),1,2),'XX') - 100)
                      + (TO_NUMBER(SUBSTR(RAWTOHEX(low_value),3,2),'XX') - 100))
               || '-' || TO_CHAR(TO_NUMBER(SUBSTR(RAWTOHEX(low_value),5,2),'XX'))
               || '-' || TO_CHAR(TO_NUMBER(SUBSTR(RAWTOHEX(low_value),7,2),'XX')),
               'YYYY-MM-DD'),
           'YYYY-MM-DD') AS low_val
FROM all_tab_columns
WHERE owner = :schema
  AND table_name = :table_name
  AND data_type = 'DATE';
```

### 3.3 ALL_COL_COMMENTS — 컬럼 커멘트

```sql
SELECT owner,
       table_name,
       column_name,
       comments
FROM all_col_comments
WHERE owner = :schema
  AND table_name = :table_name
  AND comments IS NOT NULL
ORDER BY column_name;
```

### 3.4 컬럼 + 커멘트 통합 조회

```sql
SELECT c.column_id,
       c.column_name,
       c.data_type ||
           CASE
               WHEN c.data_type IN ('VARCHAR2','CHAR','NVARCHAR2','RAW')
                   THEN '(' || c.data_length || ')'
               WHEN c.data_type = 'NUMBER' AND c.data_precision IS NOT NULL
                   THEN '(' || c.data_precision || ',' || c.data_scale || ')'
               ELSE ''
           END AS data_type_full,
       c.nullable,
       c.num_distinct,
       c.num_nulls,
       c.histogram,
       cc.comments AS column_comment
FROM all_tab_columns c
LEFT JOIN all_col_comments cc
    ON cc.owner = c.owner
   AND cc.table_name = c.table_name
   AND cc.column_name = c.column_name
WHERE c.owner = :schema
  AND c.table_name = :table_name
ORDER BY c.column_id;
```

출력 예시:

```
COLUMN_ID  COLUMN_NAME    DATA_TYPE_FULL   NULLABLE  NUM_DISTINCT  HISTOGRAM   COLUMN_COMMENT
---------  ------------   ---------------  --------  ------------  ----------  ----------------
1          ORDER_ID       NUMBER(10,0)     N         50000         NONE        주문 고유 번호
2          ORDER_DATE     DATE             N         365           HYBRID      주문 일자
3          CUSTOMER_ID    NUMBER(10,0)     N         12000         FREQUENCY   고객 ID (FK)
4          STATUS         VARCHAR2(20)     Y         5             FREQUENCY   주문 상태 (ACTIVE/CLOSED/...)
5          TOTAL_AMOUNT   NUMBER(12,2)     Y         48000         HEIGHT BAL  주문 총액
```

---

## 4. 인덱스 정보

### 4.1 ALL_INDEXES — 인덱스 기본 정보

```sql
SELECT index_name,
       table_name,
       uniqueness,
       index_type,
       status,
       num_rows,
       leaf_blocks,
       distinct_keys,
       clustering_factor,
       TO_CHAR(last_analyzed, 'YYYY-MM-DD HH24:MI:SS') AS last_analyzed,
       visibility
FROM all_indexes
WHERE owner = :schema
  AND table_name = :table_name
ORDER BY index_name;
```

| 컬럼 | 설명 | 분석 활용 |
|------|------|----------|
| `UNIQUENESS` | UNIQUE / NONUNIQUE | 유니크 인덱스는 선택도 = 1 |
| `INDEX_TYPE` | NORMAL, BITMAP, FUNCTION-BASED 등 | 인덱스 접근 방식 |
| `DISTINCT_KEYS` | 고유 키 수 | 인덱스 선택도 |
| `CLUSTERING_FACTOR` | 클러스터링 팩터 | BLOCKS에 가까우면 좋음, NUM_ROWS에 가까우면 나쁨 |
| `VISIBILITY` | VISIBLE / INVISIBLE | Invisible 인덱스는 옵티마이저가 무시 |

### 4.2 ALL_IND_COLUMNS — 인덱스 컬럼 구성

```sql
SELECT index_name,
       column_name,
       column_position,
       descend
FROM all_ind_columns
WHERE index_owner = :schema
  AND table_name = :table_name
ORDER BY index_name, column_position;
```

### 4.3 인덱스 + 컬럼 통합 조회

```sql
SELECT i.index_name,
       i.uniqueness,
       i.index_type,
       i.status,
       i.distinct_keys,
       i.clustering_factor,
       i.visibility,
       LISTAGG(ic.column_name, ', ')
           WITHIN GROUP (ORDER BY ic.column_position) AS columns
FROM all_indexes i
JOIN all_ind_columns ic
    ON ic.index_owner = i.owner AND ic.index_name = i.index_name
WHERE i.owner = :schema
  AND i.table_name = :table_name
GROUP BY i.index_name, i.uniqueness, i.index_type,
         i.status, i.distinct_keys, i.clustering_factor, i.visibility
ORDER BY i.index_name;
```

---

## 5. 제약 조건

### 5.1 ALL_CONSTRAINTS — PK, FK, UK, CHECK

```sql
SELECT constraint_name,
       constraint_type,
       search_condition,
       r_constraint_name,
       status,
       deferrable,
       validated
FROM all_constraints
WHERE owner = :schema
  AND table_name = :table_name
ORDER BY constraint_type, constraint_name;
```

| CONSTRAINT_TYPE | 설명 |
|----------------|------|
| `P` | Primary Key |
| `U` | Unique |
| `R` | Foreign Key (References) |
| `C` | Check (NOT NULL 포함) |

### 5.2 ALL_CONS_COLUMNS — 제약 조건 컬럼

```sql
SELECT cc.constraint_name,
       c.constraint_type,
       cc.column_name,
       cc.position,
       c.r_constraint_name,
       -- FK인 경우 참조 대상 테이블
       (SELECT table_name FROM all_constraints
        WHERE owner = c.r_owner AND constraint_name = c.r_constraint_name) AS ref_table
FROM all_cons_columns cc
JOIN all_constraints c
    ON c.owner = cc.owner AND c.constraint_name = cc.constraint_name
WHERE cc.owner = :schema
  AND cc.table_name = :table_name
ORDER BY c.constraint_type, cc.constraint_name, cc.position;
```

---

## 6. 파티션 정보

### 6.1 ALL_PART_TABLES — 파티셔닝 전략

```sql
SELECT table_name,
       partitioning_type,
       subpartitioning_type,
       partition_count,
       def_tablespace_name,
       interval
FROM all_part_tables
WHERE owner = :schema
  AND table_name = :table_name;
```

### 6.2 ALL_PART_KEY_COLUMNS — 파티션 키 컬럼

```sql
SELECT name AS table_name,
       column_name,
       column_position
FROM all_part_key_columns
WHERE owner = :schema
  AND name = :table_name
  AND object_type = 'TABLE'
ORDER BY column_position;
```

### 6.3 ALL_TAB_PARTITIONS — 파티션 목록 + 통계

```sql
SELECT partition_name,
       high_value,
       num_rows,
       blocks,
       TO_CHAR(last_analyzed, 'YYYY-MM-DD HH24:MI:SS') AS last_analyzed,
       tablespace_name
FROM all_tab_partitions
WHERE table_owner = :schema
  AND table_name = :table_name
ORDER BY partition_position;
```

---

## 7. 종합 조회: 테이블 + 컬럼 + 커멘트 + 인덱스

하나의 테이블에 대해 분석에 필요한 전체 메타데이터를 한 번에 조회하는 쿼리.

### 7.1 테이블 요약

```sql
SELECT t.table_name,
       tc.comments AS table_comment,
       t.num_rows,
       t.blocks,
       t.avg_row_len,
       t.partitioned,
       t.temporary,
       TO_CHAR(t.last_analyzed, 'YYYY-MM-DD HH24:MI:SS') AS last_analyzed
FROM all_tables t
LEFT JOIN all_tab_comments tc
    ON tc.owner = t.owner AND tc.table_name = t.table_name
WHERE t.owner = :schema
  AND t.table_name = :table_name;
```

### 7.2 컬럼 상세 (커멘트 포함)

```sql
SELECT c.column_id AS "#",
       c.column_name,
       c.data_type ||
           CASE
               WHEN c.data_type IN ('VARCHAR2','CHAR','NVARCHAR2','RAW')
                   THEN '(' || c.data_length || ')'
               WHEN c.data_type = 'NUMBER' AND c.data_precision IS NOT NULL
                   THEN '(' || c.data_precision || ',' || c.data_scale || ')'
               ELSE ''
           END AS data_type,
       DECODE(c.nullable, 'N', 'NOT NULL', '') AS nullable,
       c.num_distinct,
       c.histogram,
       cc.comments AS comment_text
FROM all_tab_columns c
LEFT JOIN all_col_comments cc
    ON cc.owner = c.owner
   AND cc.table_name = c.table_name
   AND cc.column_name = c.column_name
WHERE c.owner = :schema
  AND c.table_name = :table_name
ORDER BY c.column_id;
```

### 7.3 인덱스 요약

```sql
SELECT i.index_name,
       i.uniqueness,
       i.index_type,
       LISTAGG(ic.column_name, ', ')
           WITHIN GROUP (ORDER BY ic.column_position) AS columns,
       i.distinct_keys,
       i.clustering_factor,
       i.status
FROM all_indexes i
JOIN all_ind_columns ic
    ON ic.index_owner = i.owner AND ic.index_name = i.index_name
WHERE i.owner = :schema
  AND i.table_name = :table_name
GROUP BY i.index_name, i.uniqueness, i.index_type,
         i.distinct_keys, i.clustering_factor, i.status
ORDER BY i.index_name;
```

### 7.4 PK/FK 관계

```sql
SELECT c.constraint_name,
       DECODE(c.constraint_type, 'P', 'PK', 'R', 'FK', 'U', 'UK', c.constraint_type) AS type,
       LISTAGG(cc.column_name, ', ')
           WITHIN GROUP (ORDER BY cc.position) AS columns,
       (SELECT table_name FROM all_constraints
        WHERE owner = c.r_owner AND constraint_name = c.r_constraint_name) AS ref_table
FROM all_constraints c
JOIN all_cons_columns cc
    ON cc.owner = c.owner AND cc.constraint_name = c.constraint_name
WHERE c.owner = :schema
  AND c.table_name = :table_name
  AND c.constraint_type IN ('P', 'R', 'U')
GROUP BY c.constraint_name, c.constraint_type, c.r_owner, c.r_constraint_name
ORDER BY c.constraint_type, c.constraint_name;
```

---

## 8. Standby DB에서의 차이점

Standby(Read-Only) 환경에서도 딕셔너리 뷰 조회는 모두 가능합니다.

| 뷰 | Primary | Standby |
|----|---------|---------|
| `ALL_TABLES` | O | O |
| `ALL_TAB_COLUMNS` | O | O |
| `ALL_TAB_COMMENTS` | O | O |
| `ALL_COL_COMMENTS` | O | O |
| `ALL_INDEXES` | O | O |
| `ALL_IND_COLUMNS` | O | O |
| `ALL_CONSTRAINTS` | O | O |
| `V$SQL_PLAN` | O | O (Shared Pool 기반) |
| `PLAN_TABLE` (INSERT) | O | **X** (Read-Only) |

> Standby에서는 `EXPLAIN PLAN`(PLAN_TABLE INSERT)이 불가하므로 `V$SQL_PLAN`에서 테이블명을 추출합니다. 딕셔너리 뷰 SELECT는 동일하게 동작합니다.

---

## 9. 커멘트 등록 방법 (참고)

분석 정확도를 높이려면 테이블/컬럼 커멘트를 등록하는 것을 권장합니다.

```sql
-- 테이블 커멘트
COMMENT ON TABLE orders IS '주문 마스터 테이블';

-- 컬럼 커멘트
COMMENT ON COLUMN orders.order_id IS '주문 고유 번호 (PK, 시퀀스 자동채번)';
COMMENT ON COLUMN orders.order_date IS '주문 일자';
COMMENT ON COLUMN orders.customer_id IS '고객 ID (customers.customer_id FK)';
COMMENT ON COLUMN orders.status IS '주문 상태: ACTIVE, SHIPPED, CLOSED, CANCELLED';
COMMENT ON COLUMN orders.total_amount IS '주문 총액 (세금 포함)';
```

커멘트가 등록되어 있으면 AI 분석 시 컬럼의 비즈니스 의미를 이해하여 더 정확한 최적화를 제안할 수 있습니다.
