# Oracle AI Query Analyzer - 아키텍처 문서

> **최종 수정일**: 2026-03-03
> **상태**: 설계 단계

---

## 1. 프로젝트 개요

Oracle DB(이하 DB1)에서 실행되는 SQL 쿼리의 실행계획을 수집하고, DB Link로 연결된 Oracle ADB(Autonomous Database)에서 LLM을 활용하여 쿼리 성능 분석 및 최적화 방안을 자동 제시하는 시스템.

### 목표

- DB1의 SQL 실행계획을 자동 수집 및 분석
- ADB의 AI 기능(DBMS_CLOUD_AI)을 활용한 지능형 쿼리 최적화 제안
- DBA/개발자가 PL/SQL 함수 하나로 간편하게 분석 결과를 받을 수 있도록 함

---

## 2. 시스템 아키텍처

### 전체 흐름

```
┌─────────────────────────┐          DB Link          ┌─────────────────────────┐
│        DB1 (Oracle)      │ ──────────────────────── │     ADB (Autonomous)     │
│                          │                           │                          │
│  ┌───────────────────┐   │    INSERT 요청            │  ┌───────────────────┐   │
│  │ query_analyzer     │   │ ────────────────────►    │  │ ai_analysis_request│   │
│  │ (PL/SQL Package)   │   │                          │  └───────┬───────────┘   │
│  │                     │   │                          │          │               │
│  │ - 실행계획 추출     │   │                          │          ▼               │
│  │ - 테이블 통계 수집  │   │                          │  ┌───────────────────┐   │
│  │ - 인덱스 정보 수집  │   │                          │  │ DBMS_SCHEDULER     │   │
│  └───────┬───────────┘   │                          │  │ (비동기 처리)      │   │
│          │               │                           │  └───────┬───────────┘   │
│          ▼               │                           │          │               │
│  ┌───────────────────┐   │    SELECT 결과            │          ▼               │
│  │ analyze_query()    │   │ ◄────────────────────    │  ┌───────────────────┐   │
│  │ (래퍼 함수)        │   │                          │  │ DBMS_CLOUD_AI      │   │
│  └───────────────────┘   │                          │  │ (LLM 호출)         │   │
│                          │                           │  └───────┬───────────┘   │
│                          │                           │          │               │
│                          │                           │          ▼               │
│                          │                           │  ┌───────────────────┐   │
│                          │                           │  │ ai_analysis_result │   │
│                          │                           │  └───────────────────┘   │
└─────────────────────────┘                           └─────────────────────────┘
```

### 통신 방식

| 구간 | 방식 | 비고 |
|------|------|------|
| DB1 → ADB | DB Link (INSERT) | 분석 요청 데이터 전송 |
| ADB 내부 | DBMS_SCHEDULER Job | LLM 호출 비동기 처리 |
| ADB → DB1 | DB Link (SELECT) | 폴링 방식으로 결과 조회 |

---

## 3. 컴포넌트 상세

### 3.1 DB1 — query_analyzer 패키지

**역할**: SQL 쿼리의 실행계획 및 관련 메타데이터 수집

**수집 데이터**:

| 항목 | 소스 | 설명 |
|------|------|------|
| 실행계획 | `DBMS_XPLAN.DISPLAY` | EXPLAIN PLAN 결과 (ALL 포맷) |
| 테이블 통계 | `USER_TABLES` | num_rows, blocks, avg_row_len, last_analyzed |
| 인덱스 정보 | `USER_INDEXES`, `USER_IND_COLUMNS` | 인덱스명, 컬럼 구성, uniqueness |
| SQL 원문 | 입력값 | 분석 대상 SQL 텍스트 |

**인터페이스**:

```sql
-- 수집 결과 레코드 타입
TYPE t_analysis_result IS RECORD (
    execution_plan   CLOB,
    table_stats      CLOB,
    index_info       CLOB,
    sql_text         CLOB
);

-- 메인 함수
FUNCTION collect_query_info(p_sql_text IN CLOB) RETURN t_analysis_result;
```

### 3.2 ADB — 요청/결과 테이블

**ai_analysis_request** (요청 테이블):

| 컬럼 | 타입 | 설명 |
|------|------|------|
| request_id | NUMBER (IDENTITY) | PK, 자동 생성 |
| sql_text | CLOB | 분석 대상 SQL |
| exec_plan | CLOB | 실행계획 텍스트 |
| table_stats | CLOB | 테이블 통계 정보 |
| index_info | CLOB | 인덱스 정보 |
| status | VARCHAR2(20) | PENDING / PROCESSING / DONE / ERROR |
| created_at | TIMESTAMP | 요청 시각 |

**ai_analysis_result** (결과 테이블):

| 컬럼 | 타입 | 설명 |
|------|------|------|
| request_id | NUMBER (FK) | 요청 ID 참조 |
| analysis | CLOB | LLM 분석 결과 |
| suggestions | CLOB | 최적화 제안사항 |
| created_at | TIMESTAMP | 결과 생성 시각 |

### 3.3 ADB — AI 분석 프로시저

**역할**: 요청 테이블에서 데이터를 읽어 LLM에 구조화된 프롬프트를 전달하고 결과 저장

**프롬프트 구성**:

```
다음 Oracle SQL의 실행계획을 분석하고 최적화 방안을 제시하세요.

## SQL
{sql_text}

## 실행계획
{exec_plan}

## 테이블 통계
{table_stats}

## 인덱스 정보
{index_info}

## 분석 요청사항
1. 성능 병목 구간 식별
2. 인덱스 활용도 평가
3. 구체적인 개선 SQL 제시
```

**LLM 호출**: `DBMS_CLOUD_AI.GENERATE` (프로파일 기반)

### 3.4 DB1 — analyze_query() 래퍼 함수

**역할**: 사용자 인터페이스. 한 번의 호출로 수집 → 요청 → 대기 → 결과 반환

**사용 예시**:

```sql
-- DBA/개발자가 호출
SELECT analyze_query('SELECT * FROM orders o JOIN customers c ON o.cust_id = c.id WHERE o.order_date > SYSDATE - 30')
FROM DUAL;
```

**타임아웃**: 기본 60초, 초과 시 request_id 반환하여 추후 조회 가능

---

## 4. 사전 준비사항

### 4.1 DB Link 설정

```sql
-- DB1에서 ADB로의 DB Link 생성
CREATE DATABASE LINK adb_link
    CONNECT TO {adb_user} IDENTIFIED BY {password}
    USING '{adb_tns_alias}';
```

### 4.2 ADB AI 프로파일 설정

```sql
-- ADB에서 AI 프로파일 생성 (OCI Generative AI 사용 시)
BEGIN
    DBMS_CLOUD_AI.CREATE_PROFILE(
        profile_name => 'MY_AI_PROFILE',
        attributes   => '{
            "provider": "oci",
            "model": "cohere.command-r-plus",
            "credential_name": "OCI_CRED",
            "oci_compartment_id": "{compartment_ocid}"
        }'
    );
END;
/
```

> **참고**: 프로바이더는 OCI Generative AI, OpenAI, Cohere 등 선택 가능.
> ADB 버전 및 라이선스에 따라 지원 범위가 다를 수 있음.

### 4.3 권한 요구사항

| 대상 | 필요 권한 |
|------|----------|
| DB1 사용자 | `CREATE DATABASE LINK`, `EXPLAIN ANY`, 대상 테이블 `SELECT` |
| ADB 사용자 | `DBMS_CLOUD_AI` 실행 권한, 테이블 생성 권한 |

---

## 5. 고려사항 및 제약

### 5.1 CLOB 전송 제한

- DB Link를 통한 CLOB 전송 시 크기 제약 가능
- 실행계획이 매우 긴 경우 요약/분할 로직 필요
- **대안**: `UTL_HTTP` 또는 AQ(Advanced Queuing) 활용

### 5.2 보안

- SQL 텍스트가 외부 LLM으로 전송되므로 민감 데이터 마스킹 고려
- DB Link 비밀번호 관리 (Oracle Wallet 사용 권장)
- AI 프로파일의 credential 보안 관리

### 5.3 성능

- LLM 응답 시간: 수 초 ~ 수십 초 소요
- 동시 다발 요청 시 ADB 부하 및 LLM API Rate Limit 고려
- 분석 이력 테이블 파티셔닝/정리(purge) 정책 필요

### 5.4 확장 가능성

- [ ] AWR/ASH 데이터 연계 분석
- [ ] 유사 쿼리 패턴 자동 탐지 및 일괄 최적화
- [ ] 분석 결과 기반 자동 인덱스 생성 제안
- [ ] Slack/Email 알림 연동
- [ ] 웹 대시보드 (분석 이력 조회, 트렌드)

---

## 6. 프로젝트 디렉토리 구조

```
oracle-ai-query-analyzer/
├── docs/
│   └── architecture.md          # 본 문서
├── src/
│   ├── db1/                     # DB1에 배포할 PL/SQL
│   │   ├── query_analyzer_pkg.sql
│   │   └── analyze_query_func.sql
│   └── adb/                     # ADB에 배포할 객체
│       ├── tables.sql
│       ├── ai_profile_setup.sql
│       ├── process_ai_analysis.sql
│       └── scheduler_job.sql
└── README.md
```

---

## 7. 구현 로드맵

| 단계 | 내용 | 상태 |
|------|------|------|
| Phase 1 | DB1 query_analyzer 패키지 구현 | DONE |
| Phase 2 | ADB 테이블 및 AI 프로파일 설정 | DONE |
| Phase 3 | ADB AI 분석 프로시저 구현 | DONE |
| Phase 4 | DB1 래퍼 함수 및 통합 테스트 | TODO |
| Phase 5 | 보안/성능 최적화 | TODO |
| Phase 6 | 확장 기능 (AWR 연계, 대시보드 등) | TODO |

---

## 변경 이력

| 날짜 | 변경 내용 | 작성자 |
|------|----------|--------|
| 2026-03-03 | 초안 작성 | - |
| 2026-03-03 | Phase 1 구현 완료 (query_analyzer_pkg, analyze_query_func) | - |
| 2026-03-03 | Phase 2 구현 완료 (tables, ai_profile_setup) | - |
| 2026-03-03 | Phase 3 구현 완료 (process_ai_analysis, scheduler_job) | - |
