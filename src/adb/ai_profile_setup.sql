/*******************************************************************************
 * AI 프로파일 설정 스크립트
 * 설명  : ADB에서 LLM을 호출하기 위한 DBMS_CLOUD_AI 프로파일 생성
 * 대상DB: ADB (Oracle Autonomous Database)
 *
 * 사전조건:
 *   - ADB 사용자에게 DBMS_CLOUD_AI 실행 권한이 부여되어 있을 것
 *   - OCI Credential이 생성되어 있을 것 (OCI 사용 시)
 *
 * 주의:
 *   - 실행 전 <<PLACEHOLDER>> 로 표시된 값을 실제 환경에 맞게 변경할 것
 *   - 프로바이더별로 하나의 섹션만 실행할 것
 *
 * 변경이력:
 *   2026-03-03  초기 작성
 ******************************************************************************/

-- ============================================================================
-- 0. 사전 확인: DBMS_CLOUD_AI 사용 가능 여부
-- ============================================================================
-- 아래 쿼리로 확인 (결과가 나오면 사용 가능)
-- SELECT * FROM all_objects WHERE object_name = 'DBMS_CLOUD_AI';

-- ============================================================================
-- 1. OCI Credential 생성 (OCI Generative AI 사용 시)
--    이미 존재하면 이 단계는 건너뜀
-- ============================================================================
/*
BEGIN
    DBMS_CLOUD.CREATE_CREDENTIAL(
        credential_name => 'OCI_AI_CRED',
        user_ocid       => '<<YOUR_USER_OCID>>',
        tenancy_ocid    => '<<YOUR_TENANCY_OCID>>',
        private_key     => '<<YOUR_API_PRIVATE_KEY>>',
        fingerprint     => '<<YOUR_API_KEY_FINGERPRINT>>'
    );
END;
/
*/

-- ============================================================================
-- 2-A. AI 프로파일: OCI Generative AI (권장)
--      Oracle Cloud 내부 통신으로 보안 및 네트워크 이점
-- ============================================================================
BEGIN
    DBMS_CLOUD_AI.CREATE_PROFILE(
        profile_name => 'QUERY_AI_PROFILE',
        attributes   => '{
            "provider": "oci",
            "credential_name": "OCI_AI_CRED",
            "model": "cohere.command-r-plus",
            "oci_compartment_id": "<<YOUR_COMPARTMENT_OCID>>",
            "temperature": 0.2,
            "max_tokens": 4096
        }'
    );
END;
/

-- ============================================================================
-- 2-B. AI 프로파일: OpenAI (대안 1)
--      ADB에서 외부 네트워크 접근이 허용되어야 함
-- ============================================================================
/*
BEGIN
    -- OpenAI API Key Credential 생성
    DBMS_CLOUD.CREATE_CREDENTIAL(
        credential_name => 'OPENAI_CRED',
        username        => 'OPENAI',
        password        => '<<YOUR_OPENAI_API_KEY>>'
    );

    DBMS_CLOUD_AI.CREATE_PROFILE(
        profile_name => 'QUERY_AI_PROFILE',
        attributes   => '{
            "provider": "openai",
            "credential_name": "OPENAI_CRED",
            "model": "gpt-4o",
            "temperature": 0.2,
            "max_tokens": 4096
        }'
    );
END;
/
*/

-- ============================================================================
-- 2-C. AI 프로파일: Azure OpenAI (대안 2)
--      기업 환경에서 Azure를 통한 OpenAI 사용 시
-- ============================================================================
/*
BEGIN
    DBMS_CLOUD.CREATE_CREDENTIAL(
        credential_name => 'AZURE_AI_CRED',
        username        => 'AZURE_OPENAI',
        password        => '<<YOUR_AZURE_API_KEY>>'
    );

    DBMS_CLOUD_AI.CREATE_PROFILE(
        profile_name => 'QUERY_AI_PROFILE',
        attributes   => '{
            "provider": "azure",
            "credential_name": "AZURE_AI_CRED",
            "azure_resource_name": "<<YOUR_AZURE_RESOURCE>>",
            "azure_deployment_name": "<<YOUR_DEPLOYMENT_NAME>>",
            "model": "gpt-4o",
            "temperature": 0.2,
            "max_tokens": 4096
        }'
    );
END;
/
*/

-- ============================================================================
-- 3. 프로파일 확인
-- ============================================================================
-- SELECT * FROM user_cloud_ai_profiles;

-- ============================================================================
-- 4. 프로파일 테스트
-- ============================================================================
/*
SELECT DBMS_CLOUD_AI.GENERATE(
    prompt       => 'Oracle SQL 튜닝에서 가장 중요한 3가지를 알려주세요.',
    profile_name => 'QUERY_AI_PROFILE',
    action       => 'chat'
) AS ai_response
FROM DUAL;
*/

-- ============================================================================
-- 유틸리티: 프로파일 삭제 (재설정 시 사용)
-- ============================================================================
/*
BEGIN
    DBMS_CLOUD_AI.DROP_PROFILE(profile_name => 'QUERY_AI_PROFILE');
END;
/
*/
