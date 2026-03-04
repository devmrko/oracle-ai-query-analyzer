/*******************************************************************************
 * ADB 테이블 DDL
 * 설명  : AI 쿼리 분석 요청/결과를 저장하는 테이블
 * 대상DB: ADB (Oracle Autonomous Database)
 *
 * 변경이력:
 *   2026-03-03  초기 작성
 ******************************************************************************/

-- ============================================================================
-- 시퀀스: 요청 ID 채번
-- ============================================================================
CREATE SEQUENCE ai_analysis_request_seq
    START WITH 1
    INCREMENT BY 1
    NOCACHE
    NOCYCLE;

-- ============================================================================
-- 테이블: AI_ANALYSIS_REQUEST (분석 요청)
-- ============================================================================
CREATE TABLE ai_analysis_request (
    request_id    NUMBER DEFAULT ai_analysis_request_seq.NEXTVAL
                  CONSTRAINT ai_req_pk PRIMARY KEY,
    sql_text      CLOB           NOT NULL,
    exec_plan     CLOB,
    table_stats   CLOB,
    index_info    CLOB,
    status        VARCHAR2(20)   DEFAULT 'PENDING'
                  CONSTRAINT ai_req_status_chk
                  CHECK (status IN ('PENDING', 'PROCESSING', 'DONE', 'ERROR')),
    error_message VARCHAR2(4000),
    source_db     VARCHAR2(128),           -- 요청 원본 DB 식별자
    requested_by  VARCHAR2(128),           -- 요청자
    created_at    TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at    TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
);

-- 인덱스: 상태별 조회 (스케줄러 Job이 PENDING 건을 조회)
CREATE INDEX ai_req_status_idx ON ai_analysis_request (status, created_at);

-- 인덱스: 생성일 기반 조회 (이력 조회, 정리용)
CREATE INDEX ai_req_created_idx ON ai_analysis_request (created_at);

COMMENT ON TABLE ai_analysis_request IS 'AI 쿼리 분석 요청 테이블';
COMMENT ON COLUMN ai_analysis_request.request_id    IS '요청 ID (PK, 자동 채번)';
COMMENT ON COLUMN ai_analysis_request.sql_text      IS '분석 대상 SQL 원문';
COMMENT ON COLUMN ai_analysis_request.exec_plan     IS 'DBMS_XPLAN 실행계획 텍스트';
COMMENT ON COLUMN ai_analysis_request.table_stats   IS '참조 테이블 통계 (JSON)';
COMMENT ON COLUMN ai_analysis_request.index_info    IS '참조 테이블 인덱스 정보 (JSON)';
COMMENT ON COLUMN ai_analysis_request.status        IS '처리 상태: PENDING / PROCESSING / DONE / ERROR';
COMMENT ON COLUMN ai_analysis_request.error_message IS '에러 발생 시 메시지';
COMMENT ON COLUMN ai_analysis_request.source_db     IS '요청 원본 DB 식별자';
COMMENT ON COLUMN ai_analysis_request.requested_by  IS '요청자 (DB 사용자명)';
COMMENT ON COLUMN ai_analysis_request.created_at    IS '요청 생성 시각';
COMMENT ON COLUMN ai_analysis_request.updated_at    IS '최종 수정 시각';

-- ============================================================================
-- 테이블: AI_ANALYSIS_RESULT (분석 결과)
-- ============================================================================
CREATE TABLE ai_analysis_result (
    result_id     NUMBER GENERATED ALWAYS AS IDENTITY
                  CONSTRAINT ai_result_pk PRIMARY KEY,
    request_id    NUMBER         NOT NULL
                  CONSTRAINT ai_result_req_fk
                  REFERENCES ai_analysis_request (request_id),
    analysis      CLOB,                    -- LLM 분석 결과 전문
    suggestions   CLOB,                    -- 구조화된 최적화 제안 (JSON)
    model_used    VARCHAR2(200),           -- 사용된 LLM 모델명
    token_count   NUMBER,                  -- 토큰 사용량 (추적용)
    elapsed_secs  NUMBER(10,2),            -- LLM 처리 소요 시간(초)
    created_at    TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE INDEX ai_result_req_idx ON ai_analysis_result (request_id);

COMMENT ON TABLE ai_analysis_result IS 'AI 쿼리 분석 결과 테이블';
COMMENT ON COLUMN ai_analysis_result.result_id    IS '결과 ID (PK, 자동 생성)';
COMMENT ON COLUMN ai_analysis_result.request_id   IS '요청 ID (FK → ai_analysis_request)';
COMMENT ON COLUMN ai_analysis_result.analysis     IS 'LLM 분석 결과 전문';
COMMENT ON COLUMN ai_analysis_result.suggestions  IS '구조화된 최적화 제안 (JSON)';
COMMENT ON COLUMN ai_analysis_result.model_used   IS '사용된 LLM 모델명';
COMMENT ON COLUMN ai_analysis_result.token_count  IS '토큰 사용량';
COMMENT ON COLUMN ai_analysis_result.elapsed_secs IS 'LLM 처리 소요 시간(초)';
COMMENT ON COLUMN ai_analysis_result.created_at   IS '결과 생성 시각';

-- ============================================================================
-- 테이블: AI_ANALYSIS_LOG (처리 로그)
-- ============================================================================
CREATE TABLE ai_analysis_log (
    log_id        NUMBER GENERATED ALWAYS AS IDENTITY
                  CONSTRAINT ai_log_pk PRIMARY KEY,
    request_id    NUMBER,
    log_level     VARCHAR2(10)   DEFAULT 'INFO'
                  CONSTRAINT ai_log_level_chk
                  CHECK (log_level IN ('INFO', 'WARN', 'ERROR', 'DEBUG')),
    message       VARCHAR2(4000),
    created_at    TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE INDEX ai_log_req_idx ON ai_analysis_log (request_id, created_at);

COMMENT ON TABLE ai_analysis_log IS 'AI 분석 처리 로그 테이블';

-- ============================================================================
-- 데이터 정리용 프로시저
-- 보관 기간이 지난 이력 데이터를 삭제
-- ============================================================================
CREATE OR REPLACE PROCEDURE purge_analysis_history(
    p_retention_days IN NUMBER DEFAULT 90
) AS
    v_cutoff_date TIMESTAMP;
    v_deleted_cnt NUMBER := 0;
BEGIN
    v_cutoff_date := SYSTIMESTAMP - NUMTODSINTERVAL(p_retention_days, 'DAY');

    -- 결과 먼저 삭제 (FK 참조)
    DELETE FROM ai_analysis_result
    WHERE request_id IN (
        SELECT request_id FROM ai_analysis_request
        WHERE created_at < v_cutoff_date
    );
    v_deleted_cnt := SQL%ROWCOUNT;

    -- 로그 삭제
    DELETE FROM ai_analysis_log
    WHERE request_id IN (
        SELECT request_id FROM ai_analysis_request
        WHERE created_at < v_cutoff_date
    );

    -- 요청 삭제
    DELETE FROM ai_analysis_request
    WHERE created_at < v_cutoff_date;
    v_deleted_cnt := v_deleted_cnt + SQL%ROWCOUNT;

    COMMIT;

    INSERT INTO ai_analysis_log (request_id, log_level, message)
    VALUES (NULL, 'INFO',
            'Purged ' || v_deleted_cnt || ' records older than ' ||
            p_retention_days || ' days');
    COMMIT;
END purge_analysis_history;
/
