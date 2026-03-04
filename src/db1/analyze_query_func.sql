/*******************************************************************************
 * Function: ANALYZE_QUERY
 * 설명    : 사용자 인터페이스 래퍼 함수
 *           쿼리를 받아 실행계획 수집 → ADB에 분석 요청 → 결과 반환
 * 대상DB  : DB1 (원본 Oracle DB)
 *
 * 사전조건:
 *   - query_analyzer 패키지가 설치되어 있을 것
 *   - ADB로의 DB Link (adb_link)가 생성되어 있을 것
 *   - ADB에 ai_analysis_request / ai_analysis_result 테이블이 존재할 것
 *
 * 사용법:
 *   SELECT analyze_query('SELECT * FROM orders WHERE status = ''ACTIVE''')
 *   FROM DUAL;
 *
 *   -- 옵션 지정
 *   SELECT analyze_query(
 *       p_sql_text => 'SELECT ...',
 *       p_schema   => 'HR',
 *       p_timeout  => 120
 *   ) FROM DUAL;
 *
 *   -- Standby DB 또는 강제 Standby 모드
 *   SELECT analyze_query(
 *       p_sql_text      => 'SELECT ...',
 *       p_sql_id        => '1abc2def3gh4',
 *       p_force_standby => 'Y'
 *   ) FROM DUAL;
 *
 * 변경이력:
 *   2026-03-03  초기 작성
 *   2026-03-04  Standby DB 지원 (p_sql_id, p_force_standby 추가, tuning_advice ADB 전달)
 ******************************************************************************/

CREATE OR REPLACE FUNCTION analyze_query(
    p_sql_text      IN CLOB,
    p_schema        IN VARCHAR2 DEFAULT NULL,
    p_timeout       IN NUMBER   DEFAULT 60,      -- 최대 대기 시간(초)
    p_db_link       IN VARCHAR2 DEFAULT 'ADB_LINK',  -- DB Link명
    p_sql_id        IN VARCHAR2 DEFAULT NULL,    -- V$SQL의 SQL_ID (Standby용)
    p_force_standby IN VARCHAR2 DEFAULT 'N'      -- 'Y'이면 Standby 경로 강제
) RETURN CLOB
IS
    v_info        query_analyzer.t_analysis_result;
    v_request_id  NUMBER;
    v_status      VARCHAR2(20);
    v_result      CLOB;
    v_elapsed     NUMBER := 0;
    v_poll_interval CONSTANT NUMBER := 2;  -- 폴링 간격(초)

    -- 동적 SQL용 변수
    v_insert_sql  VARCHAR2(4000);
    v_select_sql  VARCHAR2(4000);
    v_result_sql  VARCHAR2(4000);
BEGIN
    ---------------------------------------------------------------------------
    -- 1) 로컬에서 실행계획 + 메타데이터 수집
    ---------------------------------------------------------------------------
    v_info := query_analyzer.collect_query_info(
        p_sql_text      => p_sql_text,
        p_schema        => p_schema,
        p_sql_id        => p_sql_id,
        p_force_standby => (UPPER(p_force_standby) = 'Y')
    );

    ---------------------------------------------------------------------------
    -- 2) ADB에 분석 요청 INSERT (DB Link)
    --    DB Link명이 파라미터이므로 동적 SQL 사용
    ---------------------------------------------------------------------------
    v_insert_sql :=
        'INSERT INTO ai_analysis_request@' || p_db_link ||
        ' (sql_text, exec_plan, table_stats, index_info, tuning_advice) ' ||
        'VALUES (:1, :2, :3, :4, :5) ' ||
        'RETURNING request_id INTO :6';

    EXECUTE IMMEDIATE v_insert_sql
        USING v_info.sql_text,
              v_info.execution_plan,
              v_info.table_stats,
              v_info.index_info,
              v_info.tuning_advice
        RETURNING INTO v_request_id;

    COMMIT;

    ---------------------------------------------------------------------------
    -- 3) 폴링으로 결과 대기
    ---------------------------------------------------------------------------
    v_select_sql :=
        'SELECT status FROM ai_analysis_request@' || p_db_link ||
        ' WHERE request_id = :1';

    LOOP
        EXECUTE IMMEDIATE v_select_sql INTO v_status USING v_request_id;

        EXIT WHEN v_status IN ('DONE', 'ERROR');
        EXIT WHEN v_elapsed >= p_timeout;

        DBMS_SESSION.SLEEP(v_poll_interval);
        v_elapsed := v_elapsed + v_poll_interval;
    END LOOP;

    ---------------------------------------------------------------------------
    -- 4) 결과 조회 및 반환
    ---------------------------------------------------------------------------
    IF v_status = 'DONE' THEN
        v_result_sql :=
            'SELECT analysis FROM ai_analysis_result@' || p_db_link ||
            ' WHERE request_id = :1';

        EXECUTE IMMEDIATE v_result_sql INTO v_result USING v_request_id;

    ELSIF v_status = 'ERROR' THEN
        v_result := '{"status":"ERROR",' ||
                    '"request_id":' || v_request_id || ',' ||
                    '"message":"ADB에서 분석 처리 중 오류가 발생했습니다."}';

    ELSE
        -- 타임아웃
        v_result := '{"status":"TIMEOUT",' ||
                    '"request_id":' || v_request_id || ',' ||
                    '"message":"분석이 아직 완료되지 않았습니다. ' ||
                    'request_id로 추후 조회하세요.",' ||
                    '"timeout_seconds":' || p_timeout || '}';
    END IF;

    RETURN v_result;

EXCEPTION
    WHEN OTHERS THEN
        RETURN '{"status":"EXCEPTION",' ||
               '"request_id":' || NVL(TO_CHAR(v_request_id), 'null') || ',' ||
               '"error_code":' || SQLCODE || ',' ||
               '"error_message":"' || REPLACE(SQLERRM, '"', '\"') || '"}';
END analyze_query;
/

/*******************************************************************************
 * Function: GET_ANALYSIS_RESULT
 * 설명    : 타임아웃된 요청의 결과를 나중에 조회하는 유틸리티 함수
 ******************************************************************************/

CREATE OR REPLACE FUNCTION get_analysis_result(
    p_request_id IN NUMBER,
    p_db_link    IN VARCHAR2 DEFAULT 'ADB_LINK'
) RETURN CLOB
IS
    v_status  VARCHAR2(20);
    v_result  CLOB;
BEGIN
    EXECUTE IMMEDIATE
        'SELECT status FROM ai_analysis_request@' || p_db_link ||
        ' WHERE request_id = :1'
        INTO v_status
        USING p_request_id;

    IF v_status = 'DONE' THEN
        EXECUTE IMMEDIATE
            'SELECT analysis FROM ai_analysis_result@' || p_db_link ||
            ' WHERE request_id = :1'
            INTO v_result
            USING p_request_id;

        RETURN v_result;

    ELSIF v_status = 'ERROR' THEN
        RETURN '{"status":"ERROR","request_id":' || p_request_id ||
               ',"message":"분석 처리 중 오류 발생"}';
    ELSE
        RETURN '{"status":"' || v_status || '","request_id":' || p_request_id ||
               ',"message":"아직 처리 중입니다."}';
    END IF;

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN '{"status":"NOT_FOUND","request_id":' || p_request_id ||
               ',"message":"해당 요청을 찾을 수 없습니다."}';
    WHEN OTHERS THEN
        RETURN '{"status":"EXCEPTION","error_code":' || SQLCODE ||
               ',"error_message":"' || REPLACE(SQLERRM, '"', '\"') || '"}';
END get_analysis_result;
/
