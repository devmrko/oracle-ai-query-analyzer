/*******************************************************************************
 * Package: AI_QUERY_PROCESSOR
 * 설명   : AI 쿼리 분석 요청을 처리하는 핵심 패키지
 *          PENDING 요청을 읽어 LLM 프롬프트 구성 → DBMS_CLOUD_AI 호출 → 결과 저장
 * 대상DB : ADB (Oracle Autonomous Database)
 *
 * 사전조건:
 *   - ai_analysis_request / ai_analysis_result / ai_analysis_log 테이블 존재
 *   - QUERY_AI_PROFILE AI 프로파일이 생성되어 있을 것
 *   - DBMS_CLOUD_AI 실행 권한
 *
 * 변경이력:
 *   2026-03-03  초기 작성
 ******************************************************************************/

-- ============================================================================
-- Package Specification
-- ============================================================================
CREATE OR REPLACE PACKAGE ai_query_processor AS

    -- 설정 상수
    c_ai_profile    CONSTANT VARCHAR2(100) := 'QUERY_ANALYZER_GROK4';
    c_max_retries   CONSTANT NUMBER := 2;       -- LLM 호출 최대 재시도
    c_batch_size    CONSTANT NUMBER := 5;       -- 한 번에 처리할 최대 요청 수

    ---------------------------------------------------------------------------
    -- process_single_request
    --   단건 요청 처리: 프롬프트 구성 → LLM 호출 → 결과 저장
    ---------------------------------------------------------------------------
    PROCEDURE process_single_request(p_request_id IN NUMBER);

    ---------------------------------------------------------------------------
    -- process_pending_requests
    --   PENDING 상태의 요청을 일괄 처리 (스케줄러에서 호출)
    ---------------------------------------------------------------------------
    PROCEDURE process_pending_requests;

    ---------------------------------------------------------------------------
    -- build_prompt
    --   요청 데이터로 LLM 프롬프트 구성
    ---------------------------------------------------------------------------
    FUNCTION build_prompt(
        p_sql_text      IN CLOB,
        p_exec_plan     IN CLOB,
        p_table_stats   IN CLOB,
        p_index_info    IN CLOB,
        p_tuning_advice IN CLOB DEFAULT NULL
    ) RETURN CLOB;

END ai_query_processor;
/

-- ============================================================================
-- Package Body
-- ============================================================================
CREATE OR REPLACE PACKAGE BODY ai_query_processor AS

    ---------------------------------------------------------------------------
    -- [내부] 로그 기록
    ---------------------------------------------------------------------------
    PROCEDURE write_log(
        p_request_id IN NUMBER,
        p_level      IN VARCHAR2,
        p_message    IN VARCHAR2
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO ai_analysis_log (request_id, log_level, message)
        VALUES (p_request_id, p_level, SUBSTR(p_message, 1, 4000));
        COMMIT;
    END write_log;

    ---------------------------------------------------------------------------
    -- [내부] 요청 상태 변경
    ---------------------------------------------------------------------------
    PROCEDURE update_request_status(
        p_request_id    IN NUMBER,
        p_status        IN VARCHAR2,
        p_error_message IN VARCHAR2 DEFAULT NULL
    ) IS
    BEGIN
        UPDATE ai_analysis_request
        SET status        = p_status,
            error_message = p_error_message,
            updated_at    = SYSTIMESTAMP
        WHERE request_id = p_request_id;
    END update_request_status;

    ---------------------------------------------------------------------------
    -- build_prompt
    ---------------------------------------------------------------------------
    FUNCTION build_prompt(
        p_sql_text      IN CLOB,
        p_exec_plan     IN CLOB,
        p_table_stats   IN CLOB,
        p_index_info    IN CLOB,
        p_tuning_advice IN CLOB DEFAULT NULL
    ) RETURN CLOB IS
        v_prompt CLOB;
    BEGIN
        DBMS_LOB.CREATETEMPORARY(v_prompt, TRUE);

        DBMS_LOB.APPEND(v_prompt,
            '당신은 Oracle Database 성능 튜닝 전문가입니다.' || CHR(10) ||
            '아래 SQL의 실행계획과 메타데이터를 분석하여 최적화 방안을 제시하세요.' || CHR(10) ||
            CHR(10));

        -- SQL 원문
        DBMS_LOB.APPEND(v_prompt,
            '## 분석 대상 SQL' || CHR(10) ||
            '```sql' || CHR(10));
        DBMS_LOB.APPEND(v_prompt, p_sql_text);
        DBMS_LOB.APPEND(v_prompt,
            CHR(10) || '```' || CHR(10) || CHR(10));

        -- 실행계획
        DBMS_LOB.APPEND(v_prompt,
            '## 실행계획 (DBMS_XPLAN)' || CHR(10) ||
            '```' || CHR(10));
        IF p_exec_plan IS NOT NULL AND DBMS_LOB.GETLENGTH(p_exec_plan) > 0 THEN
            DBMS_LOB.APPEND(v_prompt, p_exec_plan);
        ELSE
            DBMS_LOB.APPEND(v_prompt, '(실행계획 없음)');
        END IF;
        DBMS_LOB.APPEND(v_prompt,
            CHR(10) || '```' || CHR(10) || CHR(10));

        -- 테이블 통계
        DBMS_LOB.APPEND(v_prompt,
            '## 테이블 통계 (JSON)' || CHR(10) ||
            '```json' || CHR(10));
        IF p_table_stats IS NOT NULL AND DBMS_LOB.GETLENGTH(p_table_stats) > 0 THEN
            DBMS_LOB.APPEND(v_prompt, p_table_stats);
        ELSE
            DBMS_LOB.APPEND(v_prompt, '[]');
        END IF;
        DBMS_LOB.APPEND(v_prompt,
            CHR(10) || '```' || CHR(10) || CHR(10));

        -- 인덱스 정보
        DBMS_LOB.APPEND(v_prompt,
            '## 인덱스 정보 (JSON)' || CHR(10) ||
            '```json' || CHR(10));
        IF p_index_info IS NOT NULL AND DBMS_LOB.GETLENGTH(p_index_info) > 0 THEN
            DBMS_LOB.APPEND(v_prompt, p_index_info);
        ELSE
            DBMS_LOB.APPEND(v_prompt, '[]');
        END IF;
        DBMS_LOB.APPEND(v_prompt,
            CHR(10) || '```' || CHR(10) || CHR(10));

        -- SQL Tuning Advisor 결과
        IF p_tuning_advice IS NOT NULL AND DBMS_LOB.GETLENGTH(p_tuning_advice) > 0 THEN
            DBMS_LOB.APPEND(v_prompt,
                '## Oracle SQL Tuning Advisor 결과 (DBMS_SQLTUNE)' || CHR(10) ||
                '```' || CHR(10));
            DBMS_LOB.APPEND(v_prompt, p_tuning_advice);
            DBMS_LOB.APPEND(v_prompt,
                CHR(10) || '```' || CHR(10) || CHR(10));
        END IF;

        -- 분석 요청사항
        DBMS_LOB.APPEND(v_prompt,
            '## 분석 요청사항' || CHR(10) ||
            '아래 항목을 구분하여 답변하세요:' || CHR(10) || CHR(10) ||
            '### 1. 실행계획 요약' || CHR(10) ||
            '- 전체 실행 흐름을 단계별로 설명' || CHR(10) ||
            '- 예상 비용(Cost)과 카디널리티(Rows) 해석' || CHR(10) || CHR(10) ||
            '### 2. 성능 병목 분석' || CHR(10) ||
            '- Full Table Scan이 발생하는 구간과 원인' || CHR(10) ||
            '- 비효율적인 조인 방식 식별' || CHR(10) ||
            '- 불필요한 Sort/Hash 연산 확인' || CHR(10) || CHR(10) ||
            '### 3. 인덱스 활용도 평가' || CHR(10) ||
            '- 현재 사용되는 인덱스와 미사용 인덱스' || CHR(10) ||
            '- 신규 인덱스 생성이 필요한 경우 DDL 제시' || CHR(10) || CHR(10) ||
            '### 4. 최적화된 SQL' || CHR(10) ||
            '- 개선된 SQL문 제시 (힌트 포함)' || CHR(10) ||
            '- 변경 사유 설명' || CHR(10) || CHR(10) ||
            '### 5. SQL Tuning Advisor 결과 해석' || CHR(10) ||
            '- Oracle이 제안한 SQL Profile, 인덱스, 대체 SQL 등의 권고 해석' || CHR(10) ||
            '- Tuning Advisor 권고의 적용 가능성과 예상 효과 평가' || CHR(10) ||
            '- Advisor 권고가 없는 경우 그 이유 분석' || CHR(10) || CHR(10) ||
            '### 6. 추가 권고사항' || CHR(10) ||
            '- 통계 갱신 필요 여부' || CHR(10) ||
            '- 파티셔닝/파라미터 변경 등 구조적 개선 제안' || CHR(10));

        RETURN v_prompt;
    END build_prompt;

    ---------------------------------------------------------------------------
    -- process_single_request
    ---------------------------------------------------------------------------
    PROCEDURE process_single_request(p_request_id IN NUMBER) IS
        v_sql_text      CLOB;
        v_exec_plan     CLOB;
        v_table_stats   CLOB;
        v_index_info    CLOB;
        v_tuning_advice CLOB;
        v_prompt        CLOB;
        v_ai_result   CLOB;
        v_start_ts    TIMESTAMP;
        v_elapsed     NUMBER;
        v_retry_cnt   NUMBER := 0;
        v_success     BOOLEAN := FALSE;
    BEGIN
        write_log(p_request_id, 'INFO', '분석 처리 시작');

        -- 1) 상태를 PROCESSING으로 변경
        update_request_status(p_request_id, 'PROCESSING');
        COMMIT;

        -- 2) 요청 데이터 조회
        SELECT sql_text, exec_plan, table_stats, index_info, tuning_advice
        INTO v_sql_text, v_exec_plan, v_table_stats, v_index_info, v_tuning_advice
        FROM ai_analysis_request
        WHERE request_id = p_request_id;

        -- 3) 프롬프트 구성
        v_prompt := build_prompt(v_sql_text, v_exec_plan, v_table_stats, v_index_info, v_tuning_advice);

        write_log(p_request_id, 'DEBUG',
                  '프롬프트 길이: ' || DBMS_LOB.GETLENGTH(v_prompt) || ' bytes');

        -- 4) LLM 호출 (재시도 포함)
        WHILE v_retry_cnt <= c_max_retries AND NOT v_success LOOP
            BEGIN
                v_start_ts := SYSTIMESTAMP;

                v_ai_result := DBMS_CLOUD_AI.GENERATE(
                    prompt       => v_prompt,
                    profile_name => c_ai_profile,
                    action       => 'chat'
                );

                v_elapsed := EXTRACT(SECOND FROM (SYSTIMESTAMP - v_start_ts)) +
                             EXTRACT(MINUTE FROM (SYSTIMESTAMP - v_start_ts)) * 60;

                v_success := TRUE;

                write_log(p_request_id, 'INFO',
                          'LLM 호출 성공. 소요시간: ' || ROUND(v_elapsed, 2) || '초');

            EXCEPTION
                WHEN OTHERS THEN
                    v_retry_cnt := v_retry_cnt + 1;
                    write_log(p_request_id, 'WARN',
                              'LLM 호출 실패 (시도 ' || v_retry_cnt || '/' ||
                              (c_max_retries + 1) || '): ' || SQLERRM);

                    IF v_retry_cnt > c_max_retries THEN
                        RAISE;
                    END IF;

                    -- 재시도 전 대기 (exponential backoff)
                    DBMS_SESSION.SLEEP(POWER(2, v_retry_cnt));
            END;
        END LOOP;

        -- 5) 결과 저장
        INSERT INTO ai_analysis_result (
            request_id, analysis, model_used, elapsed_secs
        ) VALUES (
            p_request_id, v_ai_result, c_ai_profile, v_elapsed
        );

        -- 6) 상태를 DONE으로 변경
        update_request_status(p_request_id, 'DONE');
        COMMIT;

        write_log(p_request_id, 'INFO', '분석 처리 완료');

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            write_log(p_request_id, 'ERROR',
                      'request_id ' || p_request_id || ' 를 찾을 수 없음');
            ROLLBACK;

        WHEN OTHERS THEN
            ROLLBACK;
            update_request_status(p_request_id, 'ERROR', SQLERRM);
            COMMIT;
            write_log(p_request_id, 'ERROR', 'LLM 처리 실패: ' || SQLERRM);
    END process_single_request;

    ---------------------------------------------------------------------------
    -- process_pending_requests
    --   PENDING 상태의 요청을 배치로 처리
    --   스케줄러 Job에서 주기적으로 호출됨
    ---------------------------------------------------------------------------
    PROCEDURE process_pending_requests IS
        CURSOR c_pending IS
            SELECT request_id
            FROM ai_analysis_request
            WHERE status = 'PENDING'
            ORDER BY created_at ASC
            FETCH FIRST c_batch_size ROWS ONLY;

        v_count NUMBER := 0;
    BEGIN
        write_log(NULL, 'INFO', '배치 처리 시작');

        FOR rec IN c_pending LOOP
            BEGIN
                process_single_request(rec.request_id);
                v_count := v_count + 1;
            EXCEPTION
                WHEN OTHERS THEN
                    -- 개별 요청 실패가 전체 배치에 영향을 주지 않도록 함
                    write_log(rec.request_id, 'ERROR',
                              '배치 내 개별 처리 실패: ' || SQLERRM);
            END;
        END LOOP;

        write_log(NULL, 'INFO', '배치 처리 완료. 처리 건수: ' || v_count);

    EXCEPTION
        WHEN OTHERS THEN
            write_log(NULL, 'ERROR', '배치 처리 중 예외: ' || SQLERRM);
    END process_pending_requests;

END ai_query_processor;
/
