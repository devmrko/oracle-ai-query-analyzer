# Oracle AI Query Analyzer

Oracle DB의 SQL 실행계획을 ADB(Autonomous Database)의 AI 기능으로 분석하여 최적화 방안을 자동 제시하는 시스템.

## 개요

```
DB1 (Oracle) ──DB Link──> ADB (Oracle Autonomous DB) ──> LLM 분석 ──> 결과 반환
```

- **DB1**: 쿼리 실행계획 + 테이블 통계 + 인덱스 정보 수집
- **ADB**: DBMS_CLOUD_AI를 통한 LLM 기반 분석 및 최적화 제안

## 사용법

```sql
-- DB1에서 실행 (Case 1/2: Primary)
SELECT analyze_query('SELECT * FROM orders WHERE order_date > SYSDATE - 30')
FROM DUAL;

-- Case 3: Standby DB
SELECT analyze_query(
    p_sql_text      => 'SELECT * FROM orders WHERE order_date > SYSDATE - 30',
    p_force_standby => 'Y'
) FROM DUAL;
```

## 4가지 적용 케이스

| 케이스 | 설명 | 라이선스 | 설명 | 플로우 | 샘플 결과 |
|--------|------|---------|------|--------|-----------|
| **Case 1** | AI 직접 분석 (Tuning Pack 없이) | EE 기본 | [설명](docs/case1_ai_direct_analysis.md) | [플로우](docs/flow_case1.md) | [리포트](docs/report_001.md) |
| **Case 2** | 튜닝팩 사용 (Advisor + AI 종합) | Tuning Pack | [설명](docs/case2_with_tuning_pack.md) | [플로우](docs/flow_case2.md) | [리포트](docs/report_002.md) |
| **Case 3** | Standby DB (Read-Only) 환경 | EE 기본 | [설명](docs/case3_standby_db.md) | [플로우](docs/flow_case3.md) | [리포트](docs/report_003.md) |
| **Case 4** | ADG + SQL Tuning Advisor | Tuning + Diag Pack | [설명](docs/case4_adg_sqltune.md) | [플로우](docs/flow_case4.md) | - |

- **Case 2 vs 3 비교**: [report_comparison.md](docs/report_comparison.md)

## 디렉토리 구조

```
oracle-ai-query-analyzer/
├── docs/
│   ├── overview.md                  # 종합 가이드 (처음 읽을 문서)
│   ├── architecture.md              # 시스템 아키텍처
│   ├── adb_setup_and_flow.md        # ADB 설정 + DB Link 연동 가이드
│   ├── case1_ai_direct_analysis.md  # Case 1 설명
│   ├── case2_with_tuning_pack.md    # Case 2 설명
│   ├── case3_standby_db.md          # Case 3 설명
│   ├── flow_case1.md                # Case 1 End-to-End 플로우
│   ├── flow_case2.md                # Case 2 End-to-End 플로우
│   ├── flow_case3.md                # Case 3 End-to-End 플로우
│   ├── case4_adg_sqltune.md         # Case 4 설명
│   ├── flow_case4.md                # Case 4 End-to-End 플로우
│   ├── report_001.md                # 샘플 리포트 (Case 1)
│   ├── report_002.md                # 샘플 리포트 (Case 2)
│   ├── report_003.md                # 샘플 리포트 (Case 3)
│   └── report_comparison.md         # 리포트 비교 (Case 2 vs 3)
├── src/
│   ├── db1/                         # DB1 배포용
│   │   ├── query_analyzer_pkg.sql   #   핵심 패키지 (Primary + Standby 지원)
│   │   ├── analyze_query_func.sql   #   래퍼 함수 (사용자 인터페이스)
│   │   ├── test_connection.py       #   배포/테스트 스크립트
│   │   ├── test_standby_mode.py     #   Standby 기능 테스트
│   │   ├── test_sqltune.py          #   Tuning Pack 권한 테스트
│   │   └── test_adg_sqltune.py     #   Case 4: ADG SQL Tuning Advisor 테스트
│   ├── adb/                         # ADB 배포용
│   │   ├── tables.sql               #   요청/결과/로그 테이블
│   │   ├── ai_profile_setup.sql     #   Credential + AI Profile
│   │   ├── process_ai_analysis.sql  #   AI 프로세서 패키지
│   │   └── scheduler_job.sql        #   DBMS_SCHEDULER Job
│   └── generate_report.py           # Markdown 리포트 생성기
├── .env                             # 환경 설정 (접속 정보, .gitignore 대상)
└── .env.example                     # 환경 설정 템플릿
```

## 참고

- **[종합 가이드](docs/overview.md)** — 처음 접하는 사람을 위한 전체 시스템 설명
- [아키텍처 문서](docs/architecture.md) — 전체 설계, 컴포넌트 상세, 권한 요구사항
- [ADB 설정 가이드](docs/adb_setup_and_flow.md) — AI Profile 설정, DB Link 구성, 트러블슈팅
- [DB Link TCPS 가이드](docs/dblink_tcps_guide.md) — Wallet 기반 TCPS DB Link 생성 (ADB + ADG)
