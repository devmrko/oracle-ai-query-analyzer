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
-- DB1에서 실행
SELECT analyze_query('SELECT * FROM orders WHERE order_date > SYSDATE - 30')
FROM DUAL;
```

## 3가지 적용 케이스

| 케이스 | 설명 | 라이선스 | 문서 |
|--------|------|---------|------|
| **Case 1** | AI 직접 분석 (Tuning Pack 없이) | EE 기본 | [case1_ai_direct_analysis.md](docs/case1_ai_direct_analysis.md) |
| **Case 2** | 튜닝팩 사용 (Advisor + AI 종합 분석) | Tuning Pack | [case2_with_tuning_pack.md](docs/case2_with_tuning_pack.md) |
| **Case 3** | Standby DB (Read-Only) 환경 | EE 기본 | [case3_standby_db.md](docs/case3_standby_db.md) |

- **Case 1**: Tuning Pack 없이도 실행계획 + 통계 + 인덱스 정보를 AI가 분석 → [샘플 결과](docs/report_001.md)
- **Case 2**: DBMS_SQLTUNE 결과까지 AI에 전달, Oracle 진단 + AI 해석 종합 분석 → [샘플 결과](docs/report_002.md)
- **Case 3**: Standby DB에서 V$ 메모리 뷰만으로 읽기 전용 분석

## 디렉토리 구조

```
oracle-ai-query-analyzer/
├── docs/
│   ├── architecture.md              # 시스템 아키텍처
│   ├── case1_ai_direct_analysis.md  # Case 1: AI 직접 분석
│   ├── case2_with_tuning_pack.md    # Case 2: 튜닝팩 사용
│   ├── case3_standby_db.md          # Case 3: Standby DB
│   ├── report_001.md                # 샘플 리포트 (Case 1)
│   └── report_002.md                # 샘플 리포트 (Case 2)
├── src/
│   ├── db1/                         # DB1 배포용
│   │   ├── query_analyzer_pkg.sql   #   핵심 패키지 (수집 로직)
│   │   ├── analyze_query_func.sql   #   래퍼 함수 (사용자 인터페이스)
│   │   ├── test_connection.py       #   배포/테스트 스크립트
│   │   ├── test_standby_mode.py     #   Standby 기능 테스트
│   │   └── test_sqltune.py          #   Tuning Pack 권한 테스트
│   ├── adb/                         # ADB 배포용
│   │   ├── tables.sql               #   요청/결과/로그 테이블
│   │   ├── ai_profile_setup.sql     #   LLM 프로파일 설정
│   │   ├── process_ai_analysis.sql  #   AI 분석 프로세서
│   │   └── scheduler_job.sql        #   DBMS_SCHEDULER Job
│   └── generate_report.py           # Markdown 리포트 생성기
└── .env                             # 환경 설정 (접속 정보)
```

## 참고

- [아키텍처 문서](docs/architecture.md) — 전체 설계, 컴포넌트 상세, 로드맵
