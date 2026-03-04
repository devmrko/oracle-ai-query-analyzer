/*******************************************************************************
 * Package: QUERY_ANALYZER
 * 설명   : SQL 쿼리의 실행계획 및 관련 메타데이터(테이블 통계, 인덱스 정보)를 수집
 * 대상DB : DB1 (원본 Oracle DB)
 *
 * 사전조건:
 *   - EXPLAIN ANY 또는 대상 테이블 SELECT 권한
 *   - PLAN_TABLE 존재 (DBMS_XPLAN 사용)
 *
 * 변경이력:
 *   2026-03-03  초기 작성
 *   2026-03-04  Standby DB 지원 추가 (듀얼 모드)
 ******************************************************************************/

-- ============================================================================
-- Package Specification
-- ============================================================================
CREATE OR REPLACE PACKAGE query_analyzer AUTHID CURRENT_USER AS

    -- 수집 결과를 담는 레코드 타입
    TYPE t_analysis_result IS RECORD (
        execution_plan   CLOB,
        table_stats      CLOB,
        index_info       CLOB,
        sql_text         CLOB,
        tuning_advice    CLOB
    );

    -- SQL에서 참조하는 테이블명 목록을 담는 테이블 타입
    TYPE t_table_list IS TABLE OF VARCHAR2(128);

    ---------------------------------------------------------------------------
    -- collect_query_info
    --   메인 함수: 쿼리를 받아 실행계획 + 통계 + 인덱스 정보를 수집하여 반환
    --
    -- Parameters:
    --   p_sql_text      : 분석 대상 SQL (SELECT 문)
    --   p_schema        : 대상 스키마 (기본값: 현재 세션 사용자)
    --   p_plan_format   : DBMS_XPLAN 출력 포맷 (기본값: 'ALL')
    --   p_sql_id        : V$SQL에서 찾은 SQL_ID (Standby 모드용)
    --   p_force_standby : TRUE이면 Primary에서도 Standby 경로 강제 사용
    --
    -- Returns:
    --   t_analysis_result 레코드
    ---------------------------------------------------------------------------
    FUNCTION collect_query_info(
        p_sql_text      IN CLOB,
        p_schema        IN VARCHAR2 DEFAULT NULL,
        p_plan_format   IN VARCHAR2 DEFAULT 'ALL',
        p_sql_id        IN VARCHAR2 DEFAULT NULL,
        p_force_standby IN BOOLEAN  DEFAULT FALSE
    ) RETURN t_analysis_result;

    ---------------------------------------------------------------------------
    -- get_execution_plan
    --   실행계획만 추출
    ---------------------------------------------------------------------------
    FUNCTION get_execution_plan(
        p_sql_text    IN CLOB,
        p_statement_id IN VARCHAR2 DEFAULT NULL,
        p_plan_format IN VARCHAR2 DEFAULT 'ALL'
    ) RETURN CLOB;

    ---------------------------------------------------------------------------
    -- get_table_stats
    --   지정된 테이블들의 통계 정보를 JSON 형태로 반환
    ---------------------------------------------------------------------------
    FUNCTION get_table_stats(
        p_tables IN t_table_list,
        p_schema IN VARCHAR2 DEFAULT NULL
    ) RETURN CLOB;

    ---------------------------------------------------------------------------
    -- get_index_info
    --   지정된 테이블들의 인덱스 정보를 JSON 형태로 반환
    ---------------------------------------------------------------------------
    FUNCTION get_index_info(
        p_tables IN t_table_list,
        p_schema IN VARCHAR2 DEFAULT NULL
    ) RETURN CLOB;

    ---------------------------------------------------------------------------
    -- extract_table_names
    --   PLAN_TABLE에서 참조 테이블명 추출 (EXPLAIN PLAN 실행 후 호출)
    ---------------------------------------------------------------------------
    FUNCTION extract_table_names(
        p_statement_id IN VARCHAR2
    ) RETURN t_table_list;

    ---------------------------------------------------------------------------
    -- get_tuning_advice
    --   DBMS_SQLTUNE을 사용하여 SQL Tuning Advisor 리포트를 반환
    --
    -- Parameters:
    --   p_sql_text   : 분석 대상 SQL
    --   p_time_limit : 튜닝 분석 제한 시간(초), 기본 30초
    --
    -- Returns:
    --   CLOB (SQL Tuning Advisor 리포트 전문)
    ---------------------------------------------------------------------------
    FUNCTION get_tuning_advice(
        p_sql_text   IN CLOB,
        p_time_limit IN NUMBER DEFAULT 30
    ) RETURN CLOB;

    ---------------------------------------------------------------------------
    -- Standby DB 지원 함수들
    ---------------------------------------------------------------------------

    ---------------------------------------------------------------------------
    -- is_standby_db
    --   현재 DB가 Standby(Read-Only)인지 판별
    ---------------------------------------------------------------------------
    FUNCTION is_standby_db RETURN BOOLEAN;

    ---------------------------------------------------------------------------
    -- get_db_role
    --   V$DATABASE.DATABASE_ROLE 값을 VARCHAR2로 반환 (SQL에서 호출 가능)
    ---------------------------------------------------------------------------
    FUNCTION get_db_role RETURN VARCHAR2;

    ---------------------------------------------------------------------------
    -- find_sql_id
    --   V$SQL에서 SQL 텍스트 앞부분을 매칭하여 SQL_ID를 검색
    ---------------------------------------------------------------------------
    FUNCTION find_sql_id(
        p_sql_text IN CLOB
    ) RETURN VARCHAR2;

    ---------------------------------------------------------------------------
    -- get_execution_plan_by_sqlid
    --   V$SQL_PLAN + DBMS_XPLAN.DISPLAY_CURSOR로 실행계획 추출 (Standby OK)
    ---------------------------------------------------------------------------
    FUNCTION get_execution_plan_by_sqlid(
        p_sql_id       IN VARCHAR2,
        p_child_number IN NUMBER   DEFAULT NULL,
        p_plan_format  IN VARCHAR2 DEFAULT 'ALL'
    ) RETURN CLOB;

    ---------------------------------------------------------------------------
    -- extract_table_names_from_cursor
    --   V$SQL_PLAN에서 참조 테이블명 추출 (Standby OK)
    ---------------------------------------------------------------------------
    FUNCTION extract_table_names_from_cursor(
        p_sql_id       IN VARCHAR2,
        p_child_number IN NUMBER DEFAULT 0
    ) RETURN t_table_list;

END query_analyzer;
/

-- ============================================================================
-- Package Body
-- ============================================================================
CREATE OR REPLACE PACKAGE BODY query_analyzer AS

    -- 내부 상수
    c_statement_prefix CONSTANT VARCHAR2(30) := 'QA_';

    ---------------------------------------------------------------------------
    -- [내부] 고유한 statement_id 생성
    ---------------------------------------------------------------------------
    FUNCTION generate_statement_id RETURN VARCHAR2 IS
    BEGIN
        RETURN c_statement_prefix || TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISSFF3');
    END generate_statement_id;

    ---------------------------------------------------------------------------
    -- [내부] PLAN_TABLE 정리
    ---------------------------------------------------------------------------
    PROCEDURE cleanup_plan_table(p_statement_id IN VARCHAR2) IS
    BEGIN
        DELETE FROM plan_table WHERE statement_id = p_statement_id;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            NULL; -- 정리 실패해도 메인 로직에 영향 없음
    END cleanup_plan_table;

    ---------------------------------------------------------------------------
    -- get_execution_plan
    ---------------------------------------------------------------------------
    FUNCTION get_execution_plan(
        p_sql_text     IN CLOB,
        p_statement_id IN VARCHAR2 DEFAULT NULL,
        p_plan_format  IN VARCHAR2 DEFAULT 'ALL'
    ) RETURN CLOB IS
        v_stmt_id      VARCHAR2(60);
        v_plan_output  CLOB;
        v_line         VARCHAR2(4000);

        CURSOR c_plan(cp_stmt_id VARCHAR2, cp_format VARCHAR2) IS
            SELECT plan_table_output
            FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', cp_stmt_id, cp_format));
    BEGIN
        v_stmt_id := NVL(p_statement_id, generate_statement_id());

        -- EXPLAIN PLAN 실행
        EXECUTE IMMEDIATE
            'EXPLAIN PLAN SET STATEMENT_ID = ''' || v_stmt_id ||
            ''' FOR ' || p_sql_text;

        -- 실행계획 텍스트 수집
        DBMS_LOB.CREATETEMPORARY(v_plan_output, TRUE);

        FOR rec IN c_plan(v_stmt_id, p_plan_format) LOOP
            DBMS_LOB.APPEND(v_plan_output, rec.plan_table_output || CHR(10));
        END LOOP;

        -- 정리
        cleanup_plan_table(v_stmt_id);

        RETURN v_plan_output;

    EXCEPTION
        WHEN OTHERS THEN
            cleanup_plan_table(v_stmt_id);
            RAISE;
    END get_execution_plan;

    ---------------------------------------------------------------------------
    -- extract_table_names
    ---------------------------------------------------------------------------
    FUNCTION extract_table_names(
        p_statement_id IN VARCHAR2
    ) RETURN t_table_list IS
        v_tables t_table_list := t_table_list();
    BEGIN
        FOR rec IN (
            SELECT DISTINCT object_name
            FROM plan_table
            WHERE statement_id = p_statement_id
              AND object_name IS NOT NULL
              AND object_type IN ('TABLE', 'TABLE (TEMP)')
            ORDER BY object_name
        ) LOOP
            v_tables.EXTEND;
            v_tables(v_tables.COUNT) := rec.object_name;
        END LOOP;

        RETURN v_tables;
    END extract_table_names;

    ---------------------------------------------------------------------------
    -- get_table_stats
    --   JSON 형태로 테이블 통계 반환
    --   예: [{"table":"ORDERS","num_rows":50000,"blocks":700,...}, ...]
    ---------------------------------------------------------------------------
    FUNCTION get_table_stats(
        p_tables IN t_table_list,
        p_schema IN VARCHAR2 DEFAULT NULL
    ) RETURN CLOB IS
        v_schema VARCHAR2(128) := NVL(p_schema, SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA'));
        v_result CLOB;
        v_first  BOOLEAN := TRUE;
    BEGIN
        DBMS_LOB.CREATETEMPORARY(v_result, TRUE);
        DBMS_LOB.APPEND(v_result, '[');

        FOR i IN 1 .. p_tables.COUNT LOOP
            FOR rec IN (
                SELECT table_name,
                       num_rows,
                       blocks,
                       avg_row_len,
                       NVL(TO_CHAR(last_analyzed, 'YYYY-MM-DD HH24:MI:SS'), 'N/A') AS last_analyzed,
                       degree,
                       partitioned,
                       temporary
                FROM all_tables
                WHERE owner = v_schema
                  AND table_name = p_tables(i)
            ) LOOP
                IF NOT v_first THEN
                    DBMS_LOB.APPEND(v_result, ',');
                END IF;
                v_first := FALSE;

                DBMS_LOB.APPEND(v_result,
                    '{' ||
                    '"table":"'         || rec.table_name     || '",' ||
                    '"num_rows":'       || NVL(TO_CHAR(rec.num_rows), 'null')    || ',' ||
                    '"blocks":'         || NVL(TO_CHAR(rec.blocks), 'null')      || ',' ||
                    '"avg_row_len":'    || NVL(TO_CHAR(rec.avg_row_len), 'null') || ',' ||
                    '"last_analyzed":"' || rec.last_analyzed   || '",' ||
                    '"degree":"'        || TRIM(rec.degree)    || '",' ||
                    '"partitioned":"'   || rec.partitioned     || '",' ||
                    '"temporary":"'     || rec.temporary       || '"' ||
                    '}'
                );
            END LOOP;
        END LOOP;

        DBMS_LOB.APPEND(v_result, ']');
        RETURN v_result;
    END get_table_stats;

    ---------------------------------------------------------------------------
    -- get_index_info
    --   JSON 형태로 인덱스 정보 반환
    --   예: [{"index":"IDX_ORDER_DATE","table":"ORDERS","columns":"ORDER_DATE",...}, ...]
    ---------------------------------------------------------------------------
    FUNCTION get_index_info(
        p_tables IN t_table_list,
        p_schema IN VARCHAR2 DEFAULT NULL
    ) RETURN CLOB IS
        v_schema  VARCHAR2(128) := NVL(p_schema, SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA'));
        v_result  CLOB;
        v_columns VARCHAR2(4000);
        v_first   BOOLEAN := TRUE;
    BEGIN
        DBMS_LOB.CREATETEMPORARY(v_result, TRUE);
        DBMS_LOB.APPEND(v_result, '[');

        FOR i IN 1 .. p_tables.COUNT LOOP
            FOR rec IN (
                SELECT i.index_name,
                       i.table_name,
                       i.uniqueness,
                       i.index_type,
                       i.status,
                       i.num_rows   AS idx_num_rows,
                       i.leaf_blocks,
                       i.distinct_keys,
                       NVL(TO_CHAR(i.last_analyzed, 'YYYY-MM-DD HH24:MI:SS'), 'N/A') AS last_analyzed
                FROM all_indexes i
                WHERE i.owner = v_schema
                  AND i.table_name = p_tables(i)
                ORDER BY i.index_name
            ) LOOP
                -- 인덱스 컬럼 목록 조합
                SELECT LISTAGG(column_name, ', ') WITHIN GROUP (ORDER BY column_position)
                INTO v_columns
                FROM all_ind_columns
                WHERE index_owner = v_schema
                  AND index_name = rec.index_name;

                IF NOT v_first THEN
                    DBMS_LOB.APPEND(v_result, ',');
                END IF;
                v_first := FALSE;

                DBMS_LOB.APPEND(v_result,
                    '{' ||
                    '"index":"'         || rec.index_name     || '",' ||
                    '"table":"'         || rec.table_name     || '",' ||
                    '"columns":"'       || v_columns          || '",' ||
                    '"uniqueness":"'    || rec.uniqueness      || '",' ||
                    '"index_type":"'    || rec.index_type      || '",' ||
                    '"status":"'        || rec.status          || '",' ||
                    '"num_rows":'       || NVL(TO_CHAR(rec.idx_num_rows), 'null')   || ',' ||
                    '"leaf_blocks":'    || NVL(TO_CHAR(rec.leaf_blocks), 'null')    || ',' ||
                    '"distinct_keys":'  || NVL(TO_CHAR(rec.distinct_keys), 'null') || ',' ||
                    '"last_analyzed":"' || rec.last_analyzed   || '"' ||
                    '}'
                );
            END LOOP;
        END LOOP;

        DBMS_LOB.APPEND(v_result, ']');
        RETURN v_result;
    END get_index_info;

    ---------------------------------------------------------------------------
    -- get_tuning_advice
    --   DBMS_SQLTUNE으로 SQL Tuning Advisor 리포트 생성
    ---------------------------------------------------------------------------
    FUNCTION get_tuning_advice(
        p_sql_text   IN CLOB,
        p_time_limit IN NUMBER DEFAULT 30
    ) RETURN CLOB IS
        v_task_name VARCHAR2(128);
        v_task_gen  VARCHAR2(128);
        v_report    CLOB;
    BEGIN
        -- 고유 Task 이름 생성
        v_task_gen := 'QA_TUNE_' || TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISSFF2');

        -- Tuning Task 생성 (VARCHAR2 오버로드 사용)
        v_task_name := DBMS_SQLTUNE.CREATE_TUNING_TASK(
            sql_text    => TO_CHAR(DBMS_LOB.SUBSTR(p_sql_text, 32767, 1)),
            time_limit  => p_time_limit,
            task_name   => v_task_gen,
            description => 'Query Analyzer auto-tuning task'
        );

        -- Task 실행
        DBMS_SQLTUNE.EXECUTE_TUNING_TASK(task_name => v_task_name);

        -- 리포트 추출
        v_report := DBMS_SQLTUNE.REPORT_TUNING_TASK(task_name => v_task_name);

        -- Task 정리
        BEGIN
            DBMS_SQLTUNE.DROP_TUNING_TASK(task_name => v_task_name);
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;

        RETURN v_report;

    EXCEPTION
        WHEN OTHERS THEN
            -- Task 정리 시도
            BEGIN
                DBMS_SQLTUNE.DROP_TUNING_TASK(task_name => v_task_gen);
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;
            RETURN 'SQL Tuning Advisor 실행 실패: ' || SQLERRM;
    END get_tuning_advice;

    ---------------------------------------------------------------------------
    -- is_standby_db
    --   V$DATABASE.DATABASE_ROLE이 'PRIMARY'가 아니면 Standby로 판별
    ---------------------------------------------------------------------------
    FUNCTION is_standby_db RETURN BOOLEAN IS
        v_role VARCHAR2(30);
    BEGIN
        EXECUTE IMMEDIATE 'SELECT database_role FROM v$database' INTO v_role;
        RETURN v_role <> 'PRIMARY';
    EXCEPTION
        WHEN OTHERS THEN
            RETURN FALSE;
    END is_standby_db;

    ---------------------------------------------------------------------------
    -- get_db_role
    --   V$DATABASE.DATABASE_ROLE을 VARCHAR2로 반환 (SQL에서 직접 호출 가능)
    ---------------------------------------------------------------------------
    FUNCTION get_db_role RETURN VARCHAR2 IS
        v_role VARCHAR2(30);
    BEGIN
        EXECUTE IMMEDIATE 'SELECT database_role FROM v$database' INTO v_role;
        RETURN v_role;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN 'UNKNOWN: ' || SQLERRM;
    END get_db_role;

    ---------------------------------------------------------------------------
    -- find_sql_id
    --   V$SQL에서 SQL 텍스트 앞 1000자를 매칭하여 가장 최근 SQL_ID를 반환
    ---------------------------------------------------------------------------
    FUNCTION find_sql_id(
        p_sql_text IN CLOB
    ) RETURN VARCHAR2 IS
        v_search   VARCHAR2(1000);
        v_sql_id   VARCHAR2(13);
    BEGIN
        -- SQL 텍스트 앞 1000자를 검색 키로 사용
        v_search := TRIM(DBMS_LOB.SUBSTR(p_sql_text, 1000, 1));

        -- 가장 최근(last_active_time 기준) SQL_ID를 찾기
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT sql_id FROM ('
                || 'SELECT sql_id FROM v$sql'
                || ' WHERE sql_text LIKE :1'
                || ' AND sql_text NOT LIKE ''%v$sql%'''
                || ' ORDER BY last_active_time DESC NULLS LAST'
                || ') WHERE ROWNUM = 1'
                INTO v_sql_id
                USING v_search || '%';
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_sql_id := NULL;
        END;

        RETURN v_sql_id;
    END find_sql_id;

    ---------------------------------------------------------------------------
    -- get_execution_plan_by_sqlid
    --   DBMS_XPLAN.DISPLAY_CURSOR를 사용하여 V$ 뷰에서 실행계획 추출
    --   V$ 뷰 읽기만 하므로 Standby DB에서도 실행 가능
    ---------------------------------------------------------------------------
    FUNCTION get_execution_plan_by_sqlid(
        p_sql_id       IN VARCHAR2,
        p_child_number IN NUMBER   DEFAULT NULL,
        p_plan_format  IN VARCHAR2 DEFAULT 'ALL'
    ) RETURN CLOB IS
        v_plan_output CLOB;
        v_child       NUMBER;
    BEGIN
        -- child_number가 지정되지 않으면 최신 것 사용
        IF p_child_number IS NULL THEN
            BEGIN
                EXECUTE IMMEDIATE
                    'SELECT MAX(child_number) FROM v$sql WHERE sql_id = :1'
                    INTO v_child
                    USING p_sql_id;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    v_child := 0;
            END;
        ELSE
            v_child := p_child_number;
        END IF;

        v_child := NVL(v_child, 0);

        DBMS_LOB.CREATETEMPORARY(v_plan_output, TRUE);

        FOR rec IN (
            SELECT plan_table_output
            FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(p_sql_id, v_child, p_plan_format))
        ) LOOP
            DBMS_LOB.APPEND(v_plan_output, rec.plan_table_output || CHR(10));
        END LOOP;

        RETURN v_plan_output;
    END get_execution_plan_by_sqlid;

    ---------------------------------------------------------------------------
    -- extract_table_names_from_cursor
    --   V$SQL_PLAN에서 참조 테이블명 추출 (Standby OK)
    ---------------------------------------------------------------------------
    FUNCTION extract_table_names_from_cursor(
        p_sql_id       IN VARCHAR2,
        p_child_number IN NUMBER DEFAULT 0
    ) RETURN t_table_list IS
        v_tables t_table_list := t_table_list();
        v_obj_name VARCHAR2(128);
        TYPE t_ref_cursor IS REF CURSOR;
        v_cur t_ref_cursor;
    BEGIN
        OPEN v_cur FOR
            'SELECT DISTINCT object_name'
            || ' FROM v$sql_plan'
            || ' WHERE sql_id = :1'
            || ' AND child_number = :2'
            || ' AND object_name IS NOT NULL'
            || ' AND object_type LIKE ''TABLE%'''
            || ' ORDER BY object_name'
            USING p_sql_id, p_child_number;

        LOOP
            FETCH v_cur INTO v_obj_name;
            EXIT WHEN v_cur%NOTFOUND;
            v_tables.EXTEND;
            v_tables(v_tables.COUNT) := v_obj_name;
        END LOOP;
        CLOSE v_cur;

        RETURN v_tables;
    END extract_table_names_from_cursor;

    ---------------------------------------------------------------------------
    -- collect_query_info (메인 함수)
    --   Standby/Primary 듀얼 모드 지원
    ---------------------------------------------------------------------------
    FUNCTION collect_query_info(
        p_sql_text      IN CLOB,
        p_schema        IN VARCHAR2 DEFAULT NULL,
        p_plan_format   IN VARCHAR2 DEFAULT 'ALL',
        p_sql_id        IN VARCHAR2 DEFAULT NULL,
        p_force_standby IN BOOLEAN  DEFAULT FALSE
    ) RETURN t_analysis_result IS
        v_result       t_analysis_result;
        v_stmt_id      VARCHAR2(60);
        v_tables       t_table_list;
        v_use_standby  BOOLEAN;
        v_sql_id       VARCHAR2(13);
        v_child_number NUMBER;
        v_cursor       INTEGER;
        v_exec_result  INTEGER;
    BEGIN
        -- Standby 모드 판별: force_standby이거나 실제 Standby DB
        v_use_standby := NVL(p_force_standby, FALSE) OR is_standby_db();

        IF v_use_standby THEN
            -----------------------------------------------------------------
            -- Standby 경로: V$ 뷰만 사용 (DML 없음)
            -----------------------------------------------------------------

            -- 1) SQL_ID 확보
            v_sql_id := p_sql_id;
            IF v_sql_id IS NULL THEN
                -- 먼저 SQL을 실행하여 Shared Pool에 캐싱
                -- (Standby에서도 SELECT는 실행 가능)
                BEGIN
                    v_cursor := DBMS_SQL.OPEN_CURSOR;
                    DBMS_SQL.PARSE(v_cursor, p_sql_text, DBMS_SQL.NATIVE);
                    v_exec_result := DBMS_SQL.EXECUTE(v_cursor);
                    DBMS_SQL.CLOSE_CURSOR(v_cursor);
                EXCEPTION
                    WHEN OTHERS THEN
                        IF DBMS_SQL.IS_OPEN(v_cursor) THEN
                            DBMS_SQL.CLOSE_CURSOR(v_cursor);
                        END IF;
                        -- 실행 실패해도 이미 캐시에 있을 수 있으므로 계속 진행
                END;

                v_sql_id := find_sql_id(p_sql_text);
            END IF;

            IF v_sql_id IS NULL THEN
                RAISE_APPLICATION_ERROR(-20001,
                    'Standby 모드: SQL 실행 후에도 V$SQL에서 해당 SQL을 찾을 수 없습니다. '
                    || 'p_sql_id 파라미터로 직접 지정해 주세요.');
            END IF;

            -- child_number 최신 값 조회
            BEGIN
                EXECUTE IMMEDIATE
                    'SELECT MAX(child_number) FROM v$sql WHERE sql_id = :1'
                    INTO v_child_number
                    USING v_sql_id;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    v_child_number := 0;
            END;
            v_child_number := NVL(v_child_number, 0);

            -- 2) DISPLAY_CURSOR로 실행계획 추출
            v_result.execution_plan := get_execution_plan_by_sqlid(
                p_sql_id       => v_sql_id,
                p_child_number => v_child_number,
                p_plan_format  => p_plan_format
            );

            -- 3) V$SQL_PLAN에서 테이블명 추출
            v_tables := extract_table_names_from_cursor(v_sql_id, NVL(v_child_number, 0));

            -- 4) 테이블 통계 & 인덱스 정보 (딕셔너리 뷰는 Standby에서도 조회 가능)
            IF v_tables.COUNT > 0 THEN
                v_result.table_stats := get_table_stats(v_tables, p_schema);
                v_result.index_info  := get_index_info(v_tables, p_schema);
            ELSE
                v_result.table_stats := '[]';
                v_result.index_info  := '[]';
            END IF;

            -- 5) Tuning Advisor는 Standby에서 실행 불가 → 스킵 메시지
            v_result.tuning_advice :=
                '[Standby DB] SQL Tuning Advisor는 Read-Only 환경에서 실행할 수 없습니다. '
                || 'Primary DB에서 analyze_query를 실행하면 튜닝 조언을 받을 수 있습니다. '
                || '(사용된 SQL_ID: ' || v_sql_id || ')';

        ELSE
            -----------------------------------------------------------------
            -- Primary 경로: 기존 로직 (EXPLAIN PLAN + DBMS_SQLTUNE)
            -----------------------------------------------------------------
            v_stmt_id := generate_statement_id();

            -- 1) EXPLAIN PLAN 실행
            EXECUTE IMMEDIATE
                'EXPLAIN PLAN SET STATEMENT_ID = ''' || v_stmt_id ||
                ''' FOR ' || p_sql_text;

            -- 2) 실행계획 텍스트 수집
            DBMS_LOB.CREATETEMPORARY(v_result.execution_plan, TRUE);
            FOR rec IN (
                SELECT plan_table_output
                FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', v_stmt_id, p_plan_format))
            ) LOOP
                DBMS_LOB.APPEND(v_result.execution_plan, rec.plan_table_output || CHR(10));
            END LOOP;

            -- 3) PLAN_TABLE에서 참조 테이블 추출
            v_tables := extract_table_names(v_stmt_id);

            -- 4) PLAN_TABLE 정리
            cleanup_plan_table(v_stmt_id);

            -- 5) 테이블 통계 수집
            IF v_tables.COUNT > 0 THEN
                v_result.table_stats := get_table_stats(v_tables, p_schema);
                v_result.index_info  := get_index_info(v_tables, p_schema);
            ELSE
                v_result.table_stats := '[]';
                v_result.index_info  := '[]';
            END IF;

            -- 6) SQL Tuning Advisor 실행
            DECLARE
                v_tune_task  VARCHAR2(128);
                v_tune_gen   VARCHAR2(128);
                v_sql_vc     VARCHAR2(32767);
            BEGIN
                v_tune_gen := 'QA_TUNE_' || TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISSFF2');
                v_sql_vc   := DBMS_LOB.SUBSTR(p_sql_text, 32767, 1);

                v_tune_task := DBMS_SQLTUNE.CREATE_TUNING_TASK(
                    sql_text   => v_sql_vc,
                    time_limit => 30,
                    task_name  => v_tune_gen
                );
                DBMS_SQLTUNE.EXECUTE_TUNING_TASK(task_name => v_tune_task);
                v_result.tuning_advice := DBMS_SQLTUNE.REPORT_TUNING_TASK(task_name => v_tune_task);

                BEGIN
                    DBMS_SQLTUNE.DROP_TUNING_TASK(task_name => v_tune_task);
                EXCEPTION WHEN OTHERS THEN NULL;
                END;
            EXCEPTION
                WHEN OTHERS THEN
                    v_result.tuning_advice := 'SQL Tuning Advisor 실행 실패: ' || SQLERRM;
                    BEGIN
                        DBMS_SQLTUNE.DROP_TUNING_TASK(task_name => v_tune_gen);
                    EXCEPTION WHEN OTHERS THEN NULL;
                    END;
            END;
        END IF;

        -- SQL 원문 저장
        v_result.sql_text := p_sql_text;

        RETURN v_result;

    EXCEPTION
        WHEN OTHERS THEN
            IF v_stmt_id IS NOT NULL THEN
                cleanup_plan_table(v_stmt_id);
            END IF;
            RAISE;
    END collect_query_info;

END query_analyzer;
/
