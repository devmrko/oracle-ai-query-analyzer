# Oracle 내부 딕셔너리 조회 가이드

> **목적**: "고객 주소 정보가 어디 있지?", "주문 상태 컬럼이 뭐지?" 같은 질문에 답하기 위해
> 테이블명, 컬럼명, 커멘트를 Oracle 딕셔너리 뷰에서 조회하는 방법.

---

## 1. 핵심 딕셔너리 뷰

| 뷰 | 용도 |
|----|------|
| `ALL_TAB_COMMENTS` | 테이블/뷰 설명 (커멘트) |
| `ALL_COL_COMMENTS` | 컬럼 설명 (커멘트) |
| `ALL_TAB_COLUMNS` | 컬럼명, 데이터 타입, NULL 여부 |
| `ALL_TABLES` | 테이블 기본 정보 (행 수 등) |

---

## 2. 테이블 찾기

### 2.1 커멘트로 테이블 검색

**"주소 관련 테이블이 뭐가 있지?"**

```sql
SELECT owner,
       table_name,
       comments
FROM all_tab_comments
WHERE comments IS NOT NULL
  AND UPPER(comments) LIKE '%주소%'
ORDER BY owner, table_name;
```

### 2.2 테이블명으로 검색

**"ADDR이 들어간 테이블은?"**

```sql
SELECT t.owner,
       t.table_name,
       c.comments AS table_comment,
       t.num_rows
FROM all_tables t
LEFT JOIN all_tab_comments c
    ON c.owner = t.owner AND c.table_name = t.table_name
WHERE t.table_name LIKE '%ADDR%'
ORDER BY t.owner, t.table_name;
```

### 2.3 특정 스키마의 전체 테이블 목록 + 커멘트

```sql
SELECT t.table_name,
       t.num_rows,
       c.comments AS table_comment
FROM all_tables t
LEFT JOIN all_tab_comments c
    ON c.owner = t.owner AND c.table_name = t.table_name
WHERE t.owner = :schema
ORDER BY t.table_name;
```

---

## 3. 컬럼 찾기

### 3.1 커멘트로 컬럼 검색

**"고객 이름이 어느 테이블 어느 컬럼에 있지?"**

```sql
SELECT owner,
       table_name,
       column_name,
       comments
FROM all_col_comments
WHERE comments IS NOT NULL
  AND UPPER(comments) LIKE '%고객%이름%'
ORDER BY owner, table_name, column_name;
```

### 3.2 컬럼명으로 검색

**"EMAIL 컬럼이 있는 테이블은?"**

```sql
SELECT c.owner,
       c.table_name,
       c.column_name,
       c.data_type,
       cc.comments AS column_comment
FROM all_tab_columns c
LEFT JOIN all_col_comments cc
    ON cc.owner = c.owner
   AND cc.table_name = c.table_name
   AND cc.column_name = c.column_name
WHERE c.column_name LIKE '%EMAIL%'
  AND c.owner = :schema
ORDER BY c.table_name, c.column_id;
```

### 3.3 테이블의 전체 컬럼 + 커멘트

**"CUSTOMERS 테이블 구조 보여줘"**

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
#  COLUMN_NAME    DATA_TYPE       NULLABLE   COLUMN_COMMENT
-  ------------   -------------   --------   ----------------------------
1  CUSTOMER_ID    NUMBER(10,0)    NOT NULL   고객 고유 번호
2  CUSTOMER_NAME  VARCHAR2(100)   NOT NULL   고객명 (한글)
3  EMAIL          VARCHAR2(200)              이메일 주소
4  PHONE          VARCHAR2(20)               전화번호
5  ADDRESS        VARCHAR2(500)              배송 주소
6  CITY           VARCHAR2(100)              도시
7  STATUS         VARCHAR2(10)    NOT NULL   상태: ACTIVE, INACTIVE
8  CREATED_AT     DATE            NOT NULL   등록일
```

---

## 4. 통합 검색: 테이블 + 컬럼 한 번에

### 4.1 키워드로 테이블/컬럼 동시 검색

**"주문 관련 테이블이나 컬럼 전부 찾아줘"**

```sql
-- 테이블 커멘트에서 검색
SELECT 'TABLE' AS type,
       owner,
       table_name,
       NULL AS column_name,
       comments
FROM all_tab_comments
WHERE owner = :schema
  AND comments IS NOT NULL
  AND UPPER(comments) LIKE '%주문%'

UNION ALL

-- 컬럼 커멘트에서 검색
SELECT 'COLUMN' AS type,
       owner,
       table_name,
       column_name,
       comments
FROM all_col_comments
WHERE owner = :schema
  AND comments IS NOT NULL
  AND UPPER(comments) LIKE '%주문%'

ORDER BY table_name, type, column_name;
```

### 4.2 테이블명 + 컬럼명 + 커멘트에서 모두 검색

**"PRICE가 들어간 모든 것"**

```sql
SELECT c.owner,
       c.table_name,
       tc.comments AS table_comment,
       c.column_name,
       c.data_type,
       cc.comments AS column_comment
FROM all_tab_columns c
LEFT JOIN all_tab_comments tc
    ON tc.owner = c.owner AND tc.table_name = c.table_name
LEFT JOIN all_col_comments cc
    ON cc.owner = c.owner
   AND cc.table_name = c.table_name
   AND cc.column_name = c.column_name
WHERE c.owner = :schema
  AND (
      c.table_name LIKE '%PRICE%'
      OR c.column_name LIKE '%PRICE%'
      OR UPPER(tc.comments) LIKE '%PRICE%'
      OR UPPER(cc.comments) LIKE '%가격%'
  )
ORDER BY c.table_name, c.column_id;
```

---

## 5. 커멘트 등록 방법

커멘트가 등록되어 있어야 검색이 가능합니다.

```sql
-- 테이블 커멘트
COMMENT ON TABLE orders IS '주문 마스터 테이블';
COMMENT ON TABLE customers IS '고객 기본정보';
COMMENT ON TABLE order_items IS '주문 상세 (주문별 품목)';

-- 컬럼 커멘트
COMMENT ON COLUMN orders.order_id IS '주문 고유 번호';
COMMENT ON COLUMN orders.order_date IS '주문 일자';
COMMENT ON COLUMN orders.customer_id IS '고객 ID';
COMMENT ON COLUMN orders.status IS '주문 상태: ACTIVE, SHIPPED, CLOSED, CANCELLED';
COMMENT ON COLUMN orders.total_amount IS '주문 총액 (세금 포함, 원화)';
```

### 커멘트 등록 현황 확인

```sql
-- 커멘트 없는 테이블 찾기
SELECT t.table_name
FROM all_tables t
LEFT JOIN all_tab_comments c
    ON c.owner = t.owner AND c.table_name = t.table_name
WHERE t.owner = :schema
  AND (c.comments IS NULL OR c.comments = '')
ORDER BY t.table_name;

-- 커멘트 없는 컬럼 찾기 (특정 테이블)
SELECT c.column_name, c.data_type
FROM all_tab_columns c
LEFT JOIN all_col_comments cc
    ON cc.owner = c.owner
   AND cc.table_name = c.table_name
   AND cc.column_name = c.column_name
WHERE c.owner = :schema
  AND c.table_name = :table_name
  AND (cc.comments IS NULL OR cc.comments = '')
ORDER BY c.column_id;
```

---

## 6. Standby DB 호환성

모든 딕셔너리 뷰 SELECT는 Standby(Read-Only)에서도 동일하게 동작합니다.

| 작업 | Primary | Standby |
|------|---------|---------|
| `ALL_TAB_COMMENTS` 조회 | O | O |
| `ALL_COL_COMMENTS` 조회 | O | O |
| `ALL_TAB_COLUMNS` 조회 | O | O |
| `COMMENT ON TABLE/COLUMN` 등록 | O | **X** (Read-Only) |
