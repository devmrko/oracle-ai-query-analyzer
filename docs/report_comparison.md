# Report 비교: Case 2 (튜닝팩) vs Case 3 (Standby DB)

> 동일한 SQL 쿼리로 Case 2와 Case 3을 실행한 결과를 비교합니다.
> 참고: [report_002.md](report_002.md) | [report_003.md](report_003.md)

---

## 1. 헤더 메타정보

| 항목 | Report 002 (Case 2) | Report 003 (Case 3) |
|------|---------------------|---------------------|
| Request ID | 3 | 5 |
| Requested By | E2E_TUNE_V2 | E2E_STANDBY |
| 분석 소요 | 56.86초 | 39.74초 |
| 사용 경로 | Primary 경로 (EXPLAIN PLAN + DBMS_SQLTUNE) | Standby 경로 (DISPLAY_CURSOR) |
| Tuning Pack | 사용 | **사용 불가 (Read-Only)** |
| SQL_ID/Child | 없음 | **0cw7jdzg1867c / Child 0** (Standby 전용) |

---

## 2. 실행계획 (Section 2) — 핵심 차이

| 항목 | Report 002 | Report 003 |
|------|------------|------------|
| 수집 방법 | `EXPLAIN PLAN` → `DBMS_XPLAN.DISPLAY` | SQL 실행 → Shared Pool → `DBMS_XPLAN.DISPLAY_CURSOR` |
| SQL_ID/SQL 텍스트 헤더 | **없음** | **있음** (SQL_ID, child number, SQL 전문 표시) |
| Query Block Name/Object Alias | **없음** | **있음** (SEL$8E99DF4F 등) |
| SELECT STATEMENT 행 | `Rows=3, Bytes=201, Cost=9(12%)` | **`Rows=빈칸, Bytes=빈칸, Cost=9(100%)`** |
| 나머지 실행계획 | 동일 | 동일 |

**핵심**: DISPLAY_CURSOR는 실제 커서에서 추출하므로 SELECT STATEMENT(Id 0)의 Rows/Bytes가 비어있고, Query Block Name 섹션이 추가됩니다.

---

## 3. 테이블 통계 / 인덱스 정보 (Section 3, 4)

**완전히 동일** — 둘 다 같은 딕셔너리 뷰(ALL_TABLES, ALL_INDEXES)에서 조회합니다.

---

## 4. SQL Tuning Advisor (Section 5) — 가장 큰 차이

| Report 002 | Report 003 |
|------------|------------|
| **전체 DBMS_SQLTUNE 결과** 포함 | **스킵 메시지** 1줄 |
| SQL Profile Finding: 11.15% 개선 | — |
| 원본 vs SQL Profile 비교 통계 (Elapsed 43.6%↓, Buffer Gets 11.11%↓ 등) | — |
| 대체 실행계획 (Plan hash 2454072086, MERGE JOIN CARTESIAN 등) | — |

Report 002는 ~130줄의 Tuning Advisor 상세 결과가 있지만, Report 003은 "Read-Only 환경에서 실행 불가" 메시지만 있습니다.

---

## 5. AI 분석 결과 (Section 6) 차이

| 항목 | Report 002 | Report 003 |
|------|------------|------------|
| 분석 범위 | 실행계획 + 통계 + 인덱스 + **Tuning Advisor** | 실행계획 + 통계 + 인덱스 **만** |
| Sections 1~4 | 거의 동일한 분석 | 거의 동일한 분석 |
| **Section 5 (Advisor 해석)** | SQL Profile 상세 해석 (Buffer Gets 11.11%↓, Physical Read 100%↓ 등) | **사용 불가** 설명 + Primary에서 실행하라는 대안 제시 |
| 인덱스 평가 | IX_SCHEDULE_AIRDT에 대해 "**Tuning Advisor SQL Profile 플랜에서 활용됨**" 언급 | 해당 언급 **없음** |
| 최적화 SQL 예상 효과 | "Tuning Advisor SQL Profile 플랜(Cost 57)보다 더 효율적일 수 있음" | 단순히 "비용 9에서 5~7로 낮아질 수 있음" |
| 추가 권고 | SQL Profile 적용 + 히스토그램 수집 | **Standby 특화**: Primary에서 DDL, V$SQL에서 SQL_ID 사전 확인, MV 복제 등 |

---

## 6. 요약

동일한 SQL에 대해:

1. **실행계획 내용 자체는 동일** (Plan hash value 1402197601) — 단, 출력 형식이 다름
2. **통계·인덱스는 완전 동일** — 같은 딕셔너리 뷰에서 조회
3. **가장 큰 차이는 Tuning Advisor** — Case 2는 SQL Profile 권고 + 상세 비교 통계 제공, Case 3은 사용 불가
4. **AI 분석도 이에 따라 차이** — Case 2는 Advisor 결과를 해석하여 더 풍부한 인사이트, Case 3은 Standby 제약에 맞춘 대안 권고
