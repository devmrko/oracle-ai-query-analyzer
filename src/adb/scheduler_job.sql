/*******************************************************************************
 * DBMS_SCHEDULER Job 설정
 * 설명  : PENDING 상태의 AI 분석 요청을 주기적으로 처리하는 스케줄러 Job
 * 대상DB: ADB (Oracle Autonomous Database)
 *
 * 사전조건:
 *   - ai_query_processor 패키지가 설치되어 있을 것
 *   - CREATE JOB 권한
 *
 * 변경이력:
 *   2026-03-03  초기 작성
 ******************************************************************************/

-- ============================================================================
-- 1. 메인 Job: PENDING 요청 처리
--    5초 간격으로 실행 (요청이 없으면 즉시 종료)
-- ============================================================================
BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'AI_ANALYSIS_PROCESSOR_JOB',
        job_type        => 'STORED_PROCEDURE',
        job_action      => 'AI_QUERY_PROCESSOR.PROCESS_PENDING_REQUESTS',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=SECONDLY;INTERVAL=5',
        enabled         => TRUE,
        auto_drop       => FALSE,
        comments        => 'PENDING 상태의 AI 쿼리 분석 요청을 주기적으로 처리'
    );
END;
/

-- ============================================================================
-- 2. 정리 Job: 오래된 이력 데이터 삭제
--    매일 새벽 2시 실행, 기본 90일 보관
-- ============================================================================
BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'AI_ANALYSIS_PURGE_JOB',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN purge_analysis_history(90); END;',
        start_date      => TRUNC(SYSTIMESTAMP) + INTERVAL '2' HOUR,  -- 오늘 02:00
        repeat_interval => 'FREQ=DAILY;BYHOUR=2;BYMINUTE=0;BYSECOND=0',
        enabled         => TRUE,
        auto_drop       => FALSE,
        comments        => '90일 지난 AI 분석 이력 자동 정리'
    );
END;
/

-- ============================================================================
-- 3. Job 상태 확인
-- ============================================================================
/*
-- 등록된 Job 목록 확인
SELECT job_name, enabled, state, last_start_date, next_run_date, run_count, failure_count
FROM user_scheduler_jobs
WHERE job_name LIKE 'AI_ANALYSIS%';

-- Job 실행 이력 확인
SELECT job_name, status, actual_start_date, run_duration, additional_info
FROM user_scheduler_job_run_details
WHERE job_name LIKE 'AI_ANALYSIS%'
ORDER BY actual_start_date DESC
FETCH FIRST 20 ROWS ONLY;
*/

-- ============================================================================
-- 4. Job 관리 유틸리티
-- ============================================================================

-- 프로세서 Job 일시 중지
/*
BEGIN
    DBMS_SCHEDULER.DISABLE('AI_ANALYSIS_PROCESSOR_JOB');
END;
/
*/

-- 프로세서 Job 재개
/*
BEGIN
    DBMS_SCHEDULER.ENABLE('AI_ANALYSIS_PROCESSOR_JOB');
END;
/
*/

-- 프로세서 Job 즉시 1회 실행 (수동 트리거)
/*
BEGIN
    DBMS_SCHEDULER.RUN_JOB('AI_ANALYSIS_PROCESSOR_JOB', use_current_session => FALSE);
END;
/
*/

-- 폴링 간격 변경 (예: 10초로 변경)
/*
BEGIN
    DBMS_SCHEDULER.SET_ATTRIBUTE(
        name      => 'AI_ANALYSIS_PROCESSOR_JOB',
        attribute => 'repeat_interval',
        value     => 'FREQ=SECONDLY;INTERVAL=10'
    );
END;
/
*/

-- Job 삭제 (재설정 시)
/*
BEGIN
    DBMS_SCHEDULER.DROP_JOB('AI_ANALYSIS_PROCESSOR_JOB', force => TRUE);
    DBMS_SCHEDULER.DROP_JOB('AI_ANALYSIS_PURGE_JOB', force => TRUE);
END;
/
*/
