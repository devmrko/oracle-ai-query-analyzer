# Exadata CA 인증서 등록 및 TCPS DB Link 생성 가이드

> **ADB에서 Exadata(자체서명 CA)로 TCPS DB Link를 생성하는 전체 절차.**
> Exadata의 CA 인증서를 Object Storage에 업로드하고, ADB Wallet에 등록한 뒤 DB Link를 생성합니다.

---

## 전체 흐름

```
┌──────────────────┐     ┌──────────────────────┐     ┌──────────────────┐
│  Exadata (DB1)    │     │  OCI Object Storage   │     │  ADB              │
│                    │     │                        │     │                    │
│  1. CA 인증서 추출 │     │  2. PEM 파일 업로드    │     │  3. Wallet에 등록  │
│     (orapki)      │────►│     (oci os put)       │────►│  4. DB Link 생성   │
│                    │     │                        │     │  5. 연결 테스트    │
└──────────────────┘     └──────────────────────┘     └──────────────────┘
```

---

## Step 1. Exadata에서 CA 인증서 추출

### 1.1 TCPS Wallet 위치 확인

```bash
# Exadata 서버에서 oracle 유저로 실행

# Wallet 위치 확인 (방법 1: sqlnet.ora)
grep -i wallet $ORACLE_HOME/network/admin/sqlnet.ora

# Wallet 위치 확인 (방법 2: listener.ora)
grep -i wallet $ORACLE_HOME/network/admin/listener.ora

# 일반적인 경로:
#   /opt/oracle/dcs/commonstore/tcps_wallet
#   /u01/app/oracle/admin/<DB명>/wallet
#   wallet_root 하위의 tls 디렉토리
```

### 1.2 Wallet 내용 확인

```bash
# Wallet에 포함된 인증서 목록 확인
orapki wallet display -wallet /opt/oracle/dcs/commonstore/tcps_wallet

# 출력 예시:
# Requested Certificates:
# User Certificates:
#   Subject: CN=pcjosdbdr-ejbyt1.pridatasbn1.datap.oraclevcn.com
# Trusted Certificates:
#   Subject: CN=pcjosdbdr-ejbyt1.pridatasbn1.datap.oraclevcn.com  ← 자체서명 CA
```

### 1.3 CA 인증서를 PEM 파일로 추출

```bash
# 방법 1: orapki로 추출
orapki wallet export -wallet /opt/oracle/dcs/commonstore/tcps_wallet \
    -dn "CN=pcjosdbdr-ejbyt1.pridatasbn1.datap.oraclevcn.com" \
    -cert /tmp/exa_ca_cert.pem

# 방법 2: openssl로 원격 추출 (Exadata 또는 네트워크 접근 가능한 곳에서)
openssl s_client -connect pcjosdbdr-ejbyt1.pridatasbn1.datap.oraclevcn.com:2484 \
    </dev/null 2>/dev/null | openssl x509 -outform PEM > /tmp/exa_ca_cert.pem
```

### 1.4 PEM 파일 확인

```bash
# 인증서 내용 확인
openssl x509 -in /tmp/exa_ca_cert.pem -text -noout

# 확인할 항목:
#   Issuer: CN = ...           ← CA 발급자
#   Subject: CN = ...          ← 서버 호스트명
#   Validity: Not After : ...  ← 만료일
```

### 1.5 RAC 2노드인 경우

각 노드의 인증서가 동일한 CA로 발급되었으면 **CA 인증서 1개만 추출**하면 됩니다.
노드별로 다른 자체서명 인증서를 사용하는 경우 **각 노드의 인증서를 모두 추출**합니다.

```bash
# 노드1 인증서
openssl s_client -connect pcjosdbdr-ejbyt1.pridatasbn1.datap.oraclevcn.com:2484 \
    </dev/null 2>/dev/null | openssl x509 -outform PEM > /tmp/exa_node1_cert.pem

# 노드2 인증서
openssl s_client -connect pcjosdbdr-ejbyt2.pridatasbn1.datap.oraclevcn.com:2484 \
    </dev/null 2>/dev/null | openssl x509 -outform PEM > /tmp/exa_node2_cert.pem

# 두 인증서의 Issuer가 같은지 확인
openssl x509 -in /tmp/exa_node1_cert.pem -noout -issuer
openssl x509 -in /tmp/exa_node2_cert.pem -noout -issuer
```

---

## Step 2. Object Storage에 업로드

### 2.1 OCI CLI로 업로드

```bash
# 버킷이 없으면 생성
oci os bucket create \
    --compartment-id <compartment_ocid> \
    --name db-certificates

# PEM 파일 업로드
oci os object put \
    --bucket-name db-certificates \
    --name exa_ca_cert.pem \
    --file /tmp/exa_ca_cert.pem

# RAC 2노드 각각 업로드하는 경우
oci os object put --bucket-name db-certificates --name exa_node1_cert.pem --file /tmp/exa_node1_cert.pem
oci os object put --bucket-name db-certificates --name exa_node2_cert.pem --file /tmp/exa_node2_cert.pem
```

### 2.2 OCI Console로 업로드

```
OCI Console → Storage → Object Storage → Buckets
  → 버킷 선택 (또는 생성)
  → Upload → exa_ca_cert.pem 파일 선택 → Upload
```

### 2.3 Object Storage URI 확인

업로드된 파일의 URI를 기록합니다:

```
https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<bucket>/o/exa_ca_cert.pem
```

---

## Step 3. ADB Wallet에 CA 인증서 등록

### 3.1 Object Storage 접근용 Credential 생성

ADB에서 Object Storage에 접근하기 위한 Credential을 생성합니다.

```sql
-- ADB에서 실행

-- 이미 OCI Credential이 있으면 이 단계 생략
BEGIN
    DBMS_CLOUD.CREATE_CREDENTIAL(
        credential_name => 'OCI_OBJ_CRED',
        user_ocid       => 'ocid1.user.oc1..<유저OCID>',
        tenancy_ocid    => 'ocid1.tenancy.oc1..<테넌시OCID>',
        private_key     => '-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBg...
-----END PRIVATE KEY-----',
        fingerprint     => 'aa:bb:cc:dd:ee:ff:...'
    );
END;
/
```

> **Resource Principal 사용 시** (OCI 내부 인증):
> ```sql
> -- Resource Principal이 활성화되어 있으면 Credential 없이 직접 접근 가능
> -- ADB 인스턴스에 Dynamic Group + Policy 설정 필요
> ```

### 3.2 ADB Wallet에 CA 인증서 추가

Object Storage에서 PEM 파일을 읽어 ADB의 Wallet에 신뢰 인증서로 등록합니다.

```sql
-- ADB에서 실행

-- CA 인증서 1개인 경우 (자체서명 CA 또는 공통 CA)
BEGIN
    DBMS_CLOUD.GET_OBJECT(
        credential_name => 'OCI_OBJ_CRED',
        object_uri      => 'https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/db-certificates/o/exa_ca_cert.pem',
        directory_name  => 'DATA_PUMP_DIR'
    );
END;
/

-- 다운로드 확인
SELECT * FROM TABLE(DBMS_CLOUD.LIST_FILES('DATA_PUMP_DIR'))
WHERE object_name LIKE '%exa%';
```

```sql
-- Wallet에 신뢰 인증서 등록
BEGIN
    DBMS_CLOUD.ADD_CERTIFICATE(
        cert_name => 'EXA_CA_CERT',
        cert      => UTL_RAW.CAST_TO_RAW(
            DBMS_CLOUD.GET_OBJECT(
                credential_name => 'OCI_OBJ_CRED',
                object_uri      => 'https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/db-certificates/o/exa_ca_cert.pem'
            )
        )
    );
END;
/
```

또는 PEM 내용을 직접 붙여넣기:

```sql
BEGIN
    DBMS_CLOUD.ADD_CERTIFICATE(
        cert_name => 'EXA_CA_CERT',
        cert      => '-----BEGIN CERTIFICATE-----
MIIDxTCCAq2gAwIBAgIJALe3...
(인증서 Base64 내용)
...dGVzdA==
-----END CERTIFICATE-----'
    );
END;
/
```

### 3.3 RAC 2노드 각각 등록하는 경우

노드별로 다른 자체서명 인증서를 사용하는 경우:

```sql
-- 노드1 인증서
BEGIN
    DBMS_CLOUD.ADD_CERTIFICATE(
        cert_name => 'EXA_NODE1_CERT',
        cert      => '-----BEGIN CERTIFICATE-----
(노드1 인증서 내용)
-----END CERTIFICATE-----'
    );
END;
/

-- 노드2 인증서
BEGIN
    DBMS_CLOUD.ADD_CERTIFICATE(
        cert_name => 'EXA_NODE2_CERT',
        cert      => '-----BEGIN CERTIFICATE-----
(노드2 인증서 내용)
-----END CERTIFICATE-----'
    );
END;
/
```

### 3.4 등록된 인증서 확인

```sql
-- 등록된 인증서 목록 조회
SELECT * FROM TABLE(DBMS_CLOUD.LIST_CERTIFICATES());
```

---

## Step 4. DB Link 생성

### 4.1 접속 Credential 생성

Exadata 접속용 Credential을 생성합니다 (Step 3의 OCI Credential과 별개).

```sql
-- ADB에서 실행
BEGIN
    DBMS_CLOUD.CREATE_CREDENTIAL(
        credential_name => 'EXA_DB_CRED',
        username        => '<exa_db_user>',
        password        => '<exa_db_password>'
    );
END;
/
```

### 4.2 TCPS DB Link 생성

```sql
-- ADB에서 실행

-- 단일 호스트
BEGIN
    DBMS_CLOUD_ADMIN.CREATE_DATABASE_LINK(
        db_link_name      => 'DBLINK_EXA',
        hostname          => '<exa_host>',
        port              => '2484',
        service_name      => '<exa_service_name>',
        credential_name   => 'EXA_DB_CRED',
        ssl_server_cert_dn => 'CN=<exa_host>'
    );
END;
/

-- RAC (다중 호스트)
BEGIN
    DBMS_CLOUD_ADMIN.CREATE_DATABASE_LINK(
        db_link_name      => 'DBLINK_EXA',
        rac_hostnames     => '["pcjosdbdr-ejbyt1.pridatasbn1.datap.oraclevcn.com",
                               "pcjosdbdr-ejbyt2.pridatasbn1.datap.oraclevcn.com"]',
        port              => '2484',
        service_name      => 'POTSDB.pridatasbn1.datap.oraclevcn.com',
        credential_name   => 'EXA_DB_CRED',
        ssl_server_cert_dn => 'CN=pcjosdbdr-ejbyt1.pridatasbn1.datap.oraclevcn.com'
    );
END;
/
```

> **`ssl_server_cert_dn`**: Step 1.2에서 확인한 인증서의 Subject DN 값.
> RAC인 경우 각 노드의 DN이 다를 수 있으므로 `ssl_server_cert_dn`을 생략하거나,
> 공통 CA의 DN을 사용합니다.

---

## Step 5. 연결 테스트

```sql
-- 기본 연결 테스트
SELECT * FROM DUAL@DBLINK_EXA;

-- Exadata 테이블 접근 확인
SELECT COUNT(*) FROM user_tables@DBLINK_EXA;

-- DB Link 정보 확인
SELECT db_link, username, host FROM user_db_links;
```

---

## 전체 절차 요약

```sql
-- ================================================================
-- Step 1: Exadata에서 CA 인증서 추출 (Exadata 서버에서 실행)
-- ================================================================
-- orapki wallet export -wallet /opt/oracle/dcs/commonstore/tcps_wallet \
--     -dn "CN=<exa_host>" -cert /tmp/exa_ca_cert.pem

-- ================================================================
-- Step 2: Object Storage에 업로드 (OCI CLI 또는 Console)
-- ================================================================
-- oci os object put --bucket-name db-certificates \
--     --name exa_ca_cert.pem --file /tmp/exa_ca_cert.pem

-- ================================================================
-- Step 3~5: ADB에서 실행
-- ================================================================

-- 3-1. OCI Object Storage Credential (이미 있으면 생략)
BEGIN
    DBMS_CLOUD.CREATE_CREDENTIAL(
        credential_name => 'OCI_OBJ_CRED',
        user_ocid       => '<유저OCID>',
        tenancy_ocid    => '<테넌시OCID>',
        private_key     => '<API Key>',
        fingerprint     => '<fingerprint>'
    );
END;
/

-- 3-2. CA 인증서를 ADB Wallet에 등록
BEGIN
    DBMS_CLOUD.ADD_CERTIFICATE(
        cert_name => 'EXA_CA_CERT',
        cert      => '-----BEGIN CERTIFICATE-----
(PEM 내용 붙여넣기)
-----END CERTIFICATE-----'
    );
END;
/

-- 4-1. Exadata 접속 Credential
BEGIN
    DBMS_CLOUD.CREATE_CREDENTIAL(
        credential_name => 'EXA_DB_CRED',
        username        => '<exa_db_user>',
        password        => '<exa_db_password>'
    );
END;
/

-- 4-2. TCPS DB Link 생성
BEGIN
    DBMS_CLOUD_ADMIN.CREATE_DATABASE_LINK(
        db_link_name      => 'DBLINK_EXA',
        rac_hostnames     => '["<node1_host>", "<node2_host>"]',
        port              => '2484',
        service_name      => '<service_name>',
        credential_name   => 'EXA_DB_CRED',
        ssl_server_cert_dn => 'CN=<exa_host>'
    );
END;
/

-- 5. 연결 테스트
SELECT * FROM DUAL@DBLINK_EXA;
```

---

## 트러블슈팅

### ORA-29024: Certificate validation failure

```
원인: ADB Wallet에 Exadata의 CA 인증서가 등록되지 않았거나 DN 불일치
해결:
  1. DBMS_CLOUD.LIST_CERTIFICATES()로 인증서가 등록되었는지 확인
  2. ssl_server_cert_dn이 실제 인증서 Subject와 일치하는지 확인
  3. RAC 환경에서 양쪽 노드의 인증서가 모두 등록되었는지 확인
  4. 인증서 만료 여부 확인
```

### ORA-12545: 대상 호스트 또는 객체가 존재하지 않아 연결에 실패

```
원인: ADB에서 Exadata 호스트로 네트워크 도달 불가
해결:
  1. ADB Private Endpoint가 Exadata와 같은 VCN/서브넷인지 확인
  2. 포트 확인: TCPS는 2484 (1521 아님!)
  3. Security List에서 2484 인바운드 허용 확인
  4. DNS 해석 확인: 호스트명이 ADB 네트워크에서 resolve 되는지
```

### ORA-28860: Fatal SSL error

```
원인: TLS 핸드셰이크 실패
해결:
  1. Exadata의 TCPS 리스너가 실제로 2484에서 동작하는지 확인
  2. PEM 파일이 올바른 형식인지 확인 (-----BEGIN/END CERTIFICATE-----)
  3. Exadata sqlnet.ora에서 SSL_CLIENT_AUTHENTICATION = FALSE 확인
```

### 인증서 관련 유틸 명령

```sql
-- 등록된 인증서 목록
SELECT * FROM TABLE(DBMS_CLOUD.LIST_CERTIFICATES());

-- 인증서 삭제 후 재등록
BEGIN
    DBMS_CLOUD.DROP_CERTIFICATE(cert_name => 'EXA_CA_CERT');
END;
/

-- DB Link 삭제 후 재생성
BEGIN
    DBMS_CLOUD_ADMIN.DROP_DATABASE_LINK(db_link_name => 'DBLINK_EXA');
END;
/
```
