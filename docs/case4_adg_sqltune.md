# Case 4: Active Data Guard + SQL Tuning Advisor

> **적용 대상**: Standby DB(ADG) 환경에서 Tuning Advisor까지 활용하고 싶은 경우
> **핵심**: Standby에서 명령을 발행하되, `database_link_to`로 실제 분석은 Primary에서 수행

---

## 1. 개요

Case 3에서는 Standby DB가 Read-Only이므로 SQL Tuning Advisor를 사용할 수 없었습니다. Case 4는 Oracle의 **Active Data Guard Support for SQL Tuning Advisor** 기능을 활용하여, Standby에서 튜닝 명령을 발행하되 실제 분석과 데이터 저장은 Primary에서 수행합니다.

```
┌──────────────────────────┐  database_link_to  ┌──────────────────────┐
│   DB1 (Standby / R-O)    │ ──────────────────► │   Primary DB         │
│                           │                      │                      │
│  수집 경로:               │   Tuning Task 위임   │  수행:               │
│  1. V$SQL → DISPLAY_CURSOR│ ──────────────────►  │  1. Task 데이터 저장 │
│  2. 통계/인덱스 수집       │                      │  2. Tuning 분석 실행 │
│  3. DBMS_SQLTUNE 호출 ★   │   리포트 반환         │  3. 결과 저장        │
│     (database_link_to)    │ ◄──────────────────  │  4. 리포트 구성      │
│  4. ADB에 요청 전송       │                      │                      │
│                           │                      │  SQL Profile →       │
│  ★ 명령은 Standby에서,   │                      │  Redo Apply →        │
│    실행은 Primary에서     │                      │  Standby에 자동 반영 │
└──────────────────────────┘                      └──────────────────────┘
        │
        │  DB Link (ADB_LINK)
        ▼
┌──────────────────────┐
│     ADB              │
│  AI 분석 (기존 흐름)  │
└──────────────────────┘
```

### Case 3과의 차이점

| 항목 | Case 3 (Standby) | Case 4 (ADG + Tuning) |
|------|------------------|----------------------|
| Tuning Advisor | **스킵** (Read-Only) | **Primary에 위임 실행** |
| DB Link | Standby → ADB | Standby → ADB + **Standby → Primary** |
| DB Link 유저 | 일반 유저 | 일반 + **SYS$UMF** (SYS 소유) |
| AI 프롬프트 | 4개 섹션 | **5개 섹션** (+Tuning Advisor) |
| SQL Profile | 적용 불가 | **Primary에 생성 → Redo Apply로 Standby 반영** |
| 라이선스 | EE 기본 | **Tuning Pack + Diagnostics Pack** |

### 전체 케이스 비교

| 수집 단계 | Case 1 (Primary, 튜닝팩 없음) | Case 2 (Primary, 튜닝팩) | Case 3 (Standby) | Case 4 (ADG + Tuning) |
|----------|------------------------------|-------------------------|------------------|----------------------|
| 실행계획 | EXPLAIN PLAN | EXPLAIN PLAN | DISPLAY_CURSOR | DISPLAY_CURSOR |
| 테이블명 | PLAN_TABLE | PLAN_TABLE | V$SQL_PLAN | V$SQL_PLAN |
| 통계/인덱스 | ALL_TABLES/INDEXES | ALL_TABLES/INDEXES | ALL_TABLES/INDEXES | ALL_TABLES/INDEXES |
| Tuning Advisor | 실패/스킵 | **로컬 실행** | **스킵** | **Primary에 위임** |
| 분석 정확도 | AI 자체 | Oracle + AI | AI 자체 | **Oracle + AI** |

---

## 2. 사전조건

### 2.1 DB Link 설정 (SYS 소유, Private)

**Standby DB에서 SYS로 접속하여** 실행:

```sql
-- Standby → Primary DB Link 생성
CREATE DATABASE LINK LNK_TO_PRI
  CONNECT TO SYS$UMF
  IDENTIFIED BY <password>
  USING '<primary_tns>';
```

**주의사항:**
- **소유자**: 반드시 `SYS`여야 합니다
- **접속 유저**: `SYS$UMF` (Oracle 내부 관리 유저)
- **타입**: Private DB Link만 가능 (Public 불가)
- Oracle 19c 이상에서 `SYS$UMF`가 자동 생성됩니다

연결 확인:
```sql
SELECT * FROM DUAL@LNK_TO_PRI;
```

### 2.2 라이선스 요구사항

| 라이선스 | 필요 여부 | 용도 |
|---------|----------|------|
| Oracle Tuning Pack | **필수** | DBMS_SQLTUNE 사용 |
| Oracle Diagnostics Pack | **필수** | ADG SQL Tuning 전제 |
| Active Data Guard Option | **필수** | Standby 읽기 접근 |

### 2.3 권한

```sql
-- Primary에서 실행
GRANT ADVISOR TO <사용자>;
GRANT EXECUTE ON DBMS_SQLTUNE TO <사용자>;
```

---

## 3. 사용하는 소스 파일

### DB1 배포 파일

| 파일 | Case 4에서의 역할 |
|------|------------------|
| `src/db1/query_analyzer_pkg.sql` | `get_tuning_advice_via_adg()` 함수 추가 — `database_link_to` 사용 |
| `src/db1/analyze_query_func.sql` | `p_primary_db_link` 파라미터 추가 |

### ADB 배포 파일 (변경 없음)

| 파일 | 역할 |
|------|------|
| `src/adb/tables.sql` | 동일 (tuning_advice 컬럼에 ADG 결과 저장) |
| `src/adb/process_ai_analysis.sql` | 동일 (tuning_advice 있으면 프롬프트에 포함) |

### 테스트

| 파일 | 역할 |
|------|------|
| `src/db1/test_adg_sqltune.py` | **Case 4 전용 5단계 테스트** |

---

## 4. 핵심 코드: `database_link_to` 사용

### `query_analyzer_pkg.sql` — `get_tuning_advice_via_adg()`

```sql
FUNCTION get_tuning_advice_via_adg(
    p_sql_text        IN CLOB,
    p_primary_db_link IN VARCHAR2,
    p_time_limit      IN NUMBER DEFAULT 30
) RETURN CLOB IS
    v_task_name VARCHAR2(128);
    v_task_gen  VARCHAR2(128);
    v_report    CLOB;
    v_sql_vc    VARCHAR2(32767);
BEGIN
    v_task_gen := 'QA_ADG_' || TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISSFF2');
    v_sql_vc  := DBMS_LOB.SUBSTR(p_sql_text, 32767, 1);

    -- ★ database_link_to로 Primary에 위임
    v_task_name := DBMS_SQLTUNE.CREATE_TUNING_TASK(
        sql_text         => v_sql_vc,
        time_limit       => p_time_limit,
        task_name        => v_task_gen,
        database_link_to => p_primary_db_link  -- ★ 핵심 파라미터
    );

    -- Standby에서 명령, Primary에서 수행
    DBMS_SQLTUNE.EXECUTE_TUNING_TASK(task_name => v_task_name);

    -- Primary에서 리포트 구성, Standby에서 조회
    v_report := DBMS_SQLTUNE.REPORT_TUNING_TASK(task_name => v_task_name);

    DBMS_SQLTUNE.DROP_TUNING_TASK(task_name => v_task_name);
    RETURN v_report;
END;
```

### `collect_query_info()` — Standby 경로 분기

```sql
-- Standby 경로에서:
IF p_primary_db_link IS NOT NULL THEN
    -- Case 4: ADG를 통해 Primary에서 Tuning Advisor 실행
    v_result.tuning_advice := get_tuning_advice_via_adg(
        p_sql_text        => p_sql_text,
        p_primary_db_link => p_primary_db_link
    );
ELSE
    -- Case 3: 스킵 메시지
    v_result.tuning_advice := '[Standby DB] SQL Tuning Advisor는 ...';
END IF;
```

---

## 5. 사용 방법

```sql
-- Standby DB에서 실행 (또는 Primary에서 p_force_standby로 테스트)
SELECT analyze_query(
    p_sql_text        => 'SELECT * FROM orders WHERE order_date > SYSDATE - 30',
    p_force_standby   => 'Y',
    p_primary_db_link => 'LNK_TO_PRI'    -- ★ Primary로의 DB Link
) FROM DUAL;

-- SQL_ID를 직접 지정하는 경우
SELECT analyze_query(
    p_sql_text        => 'SELECT ...',
    p_sql_id          => '5x062n59sxus4',
    p_force_standby   => 'Y',
    p_primary_db_link => 'LNK_TO_PRI'
) FROM DUAL;
```

### 동작 방식

```
analyze_query() 호출
    │
    ├── 1. Standby 경로 감지 (p_force_standby='Y' 또는 자동)
    │
    ├── 2. V$SQL/V$SQL_PLAN으로 실행계획 수집 (Case 3과 동일)
    │
    ├── 3. 통계/인덱스 수집 (Case 3과 동일)
    │
    ├── 4. ★ p_primary_db_link가 있으므로 ADG Tuning 실행
    │       └── get_tuning_advice_via_adg()
    │             ├── CREATE_TUNING_TASK(database_link_to => 'LNK_TO_PRI')
    │             │     → Task 데이터가 Primary에 저장됨
    │             ├── EXECUTE_TUNING_TASK
    │             │     → Primary에서 분석 수행
    │             ├── REPORT_TUNING_TASK
    │             │     → Primary에서 리포트 구성, Standby에서 수신
    │             └── DROP_TUNING_TASK
    │
    ├── 5. ADB에 INSERT (DB Link) — tuning_advice에 ADG 결과 포함
    │
    └── 6. ADB AI 분석 → 결과 반환
          (Case 2와 동일한 5개 섹션 프롬프트)
```

---

## 6. 테스트

### 테스트 스크립트 실행

```bash
cd src/db1

# PRIMARY_DB_LINK 환경변수로 DB Link명 지정 (기본값: LNK_TO_PRI)
export PRIMARY_DB_LINK=LNK_TO_PRI

python test_adg_sqltune.py
```

### 5단계 테스트 항목

| 테스트 | 내용 | 검증 포인트 |
|--------|------|------------|
| 1. DB Link 연결 | `SELECT * FROM DUAL@LNK_TO_PRI` | Primary 연결 확인 |
| 2. SYS$UMF 유저 | DBA_USERS에서 확인 | 유저 존재/활성 상태 |
| 3. ADG Tuning 직접 실행 | `get_tuning_advice_via_adg()` | 리포트 반환 성공 |
| 4. 전체 플로우 | `collect_query_info(p_primary_db_link)` | 5개 필드 모두 반환 |
| 5. Case 3 vs 4 비교 | 동일 SQL로 비교 | Case 4의 tuning_advice가 더 상세 |

### 예상 결과

```
테스트 결과 요약
============================================================
  [OK]   Primary DB Link 연결
  [OK]   SYS$UMF 유저 확인
  [OK]   ADG SQL Tuning Advisor
  [OK]   collect_query_info + ADG
  [OK]   Case 3 vs Case 4 비교

모든 테스트 통과!
```

---

## 7. SQL Profile 자동 반영

ADG를 통해 생성된 SQL Profile은 Primary에 저장됩니다. Redo Apply를 통해 Standby에도 자동 반영됩니다.

```
Primary: ACCEPT_SQL_PROFILE → SQL Profile 생성
    │
    ▼ Redo Apply
Standby: SQL Profile 자동 적용 → 동일 SQL에 자동 반영
```

SQL Profile 적용:
```sql
-- Standby에서 실행 (database_link_to 사용)
BEGIN
    DBMS_SQLTUNE.ACCEPT_SQL_PROFILE(
        task_name        => 'QA_ADG_...',
        database_link_to => 'LNK_TO_PRI'    -- Primary에 Profile 생성
    );
END;
/
```

---

## 8. 제한 사항

### 8.1 SYS 소유 DB Link 필수

`database_link_to`에 사용되는 DB Link는 **반드시 SYS가 소유**해야 합니다. 일반 유저 소유 DB Link를 사용하면 `ORA-02019` 또는 권한 오류가 발생합니다.

### 8.2 모든 명령은 Standby에서 발행

Primary에서 `database_link_to`를 사용하는 것이 아닙니다. **Standby에서** 모든 DBMS_SQLTUNE 명령을 실행하되, 실제 작업이 Primary에서 수행되는 구조입니다.

### 8.3 Oracle 버전 요구사항

- `database_link_to` 파라미터는 **Oracle 19c 이상**에서 지원됩니다
- `SYS$UMF` 유저도 19c 이상에서 자동 생성됩니다

### 8.4 네트워크 요구사항

Standby와 Primary 간 네트워크 연결이 안정적이어야 합니다. Tuning Task 실행 중 연결이 끊기면 Task가 Primary에 남을 수 있습니다.

---

## 9. 트러블슈팅

### DB Link 관련

```sql
-- DB Link 확인 (SYS로 접속)
SELECT owner, db_link, username FROM dba_db_links
WHERE db_link = 'LNK_TO_PRI';

-- 연결 테스트
SELECT * FROM DUAL@LNK_TO_PRI;
```

### Tuning Task가 Primary에 남은 경우

```sql
-- Primary에서 확인
SELECT task_name, status FROM dba_advisor_tasks
WHERE task_name LIKE 'QA_ADG_%';

-- 정리
BEGIN
    DBMS_SQLTUNE.DROP_TUNING_TASK(task_name => 'QA_ADG_...');
END;
/
```

### ORA-01031: insufficient privileges

```sql
-- Primary에서 권한 부여
GRANT ADVISOR TO <사용자>;
GRANT EXECUTE ON DBMS_SQLTUNE TO <사용자>;
GRANT ADMINISTER SQL TUNING SET TO <사용자>;
```
