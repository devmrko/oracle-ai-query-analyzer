# DB Link 생성 가이드 (TCPS / Wallet 기반)

> **ADB(Autonomous Database)에서 DB1(원본 Oracle DB)로의 DB Link 생성 절차.**
> DB1이 TCPS(TLS) 접속을 사용하는 경우 Wallet 설정이 필요.

---

## 1. 개요

이 시스템에서 사용하는 DB Link 방향:

```
ADB ──── DB Link (DB1_LINK) ────► DB1
  │                                  │
  │  ADB에서 DB1의 데이터를          │
  │  원격 조회/분석                   │
  └──────────────────────────────────┘
```

| 항목 | 값 |
|------|---|
| DB Link 생성 위치 | **ADB** |
| 접속 대상 | **DB1** (원본 Oracle DB) |
| 프로토콜 | TCPS (TLS 암호화) |
| 필요 파일 | DB1 서버의 인증서가 포함된 Wallet |

---

## 2. 사전 준비

### 2.1 DB1 서버 TCPS 설정 확인

DB1이 TCPS로 리스닝하고 있는지 확인합니다.

```sql
-- DB1에서 실행
SELECT * FROM v$listener_network;

-- 또는 서버에서 직접 확인
lsnrctl status
```

TCPS 리스너 항목이 있어야 합니다:
```
(DESCRIPTION=(ADDRESS=(PROTOCOL=tcps)(HOST=<db1_host>)(PORT=<tcps_port>)))
```

### 2.2 DB1 TCPS Wallet 위치 확인

DB1 서버에서 TCPS에 사용하는 Wallet 경로를 확인합니다.

```sql
-- DB1에서 실행
SHOW PARAMETER wallet_root;
-- 예: /opt/oracle/dcs/commonstore/wallets/DB0225_ggt_icn

-- 또는 sqlnet.ora에서 확인
-- $ORACLE_HOME/network/admin/sqlnet.ora
-- WALLET_LOCATION → (DIRECTORY = /opt/oracle/dcs/commonstore/tcps_wallet)
```

### 2.3 DB1 인증서를 ADB Wallet에 등록

ADB에서 DB1으로 TCPS 접속하려면, **DB1의 서버 인증서(CA)**를 ADB가 신뢰할 수 있어야 합니다.

#### 방법 1: DB1이 공인 CA 인증서를 사용하는 경우

OCI DB System의 TCPS는 기본적으로 OCI 내부 CA를 사용합니다. 같은 OCI 환경이면 별도 작업 없이 접속 가능합니다.

#### 방법 2: DB1이 자체 서명 인증서를 사용하는 경우

DB1의 CA 인증서를 ADB의 Wallet에 추가해야 합니다.

```sql
-- ADB에서 실행
-- 1) DB1의 CA 인증서를 Object Storage에 업로드 후

-- 2) ADB Wallet에 신뢰 인증서 추가
BEGIN
    DBMS_CLOUD.CREATE_CREDENTIAL(
        credential_name => 'DB1_CERT_CRED',
        username        => '<oci_user>',
        password        => '<auth_token>'
    );
END;
/
```

> **OCI DB System 간 연결**: 같은 VCN/서브넷이면 TCP(1521)로 접속하는 것이 더 간단합니다. TCPS가 필수가 아니라면 섹션 5를 참고하세요.

---

## 3. ADB에서 DB Link 생성

### 3.1 방법 1: DBMS_CLOUD.CREATE_DATABASE_LINK 사용 (권장)

ADB에서는 `CREATE DATABASE LINK` DDL 대신 `DBMS_CLOUD` 패키지를 사용합니다.

#### TCPS 접속 (Wallet 사용)

```sql
-- ADB에서 실행
BEGIN
    DBMS_CLOUD.CREATE_DATABASE_LINK(
        db_link_name => 'DB1_LINK',
        hostname     => '<db1_host>',
        port         => <tcps_port>,
        service_name => '<db1_service_name>',
        ssl_server_cert_dn => '<db1_cert_dn>',
        username     => '<db1_user>',
        password     => '<db1_password>'
    );
END;
/
```

| 파라미터 | 설명 | 예시 |
|---------|------|------|
| `hostname` | DB1 서버 호스트 | `db1.subnet.vcn.oraclevcn.com` |
| `port` | DB1 TCPS 포트 | `2484` (기본 TCPS 포트) |
| `service_name` | DB1 PDB 서비스명 | `db0225_pdb1.subnet.vcn.oraclevcn.com` |
| `ssl_server_cert_dn` | DB1 서버 인증서 DN | `CN=db1.subnet.vcn.oraclevcn.com` |
| `username` | DB1 접속 유저 | `system` |
| `password` | DB1 접속 비밀번호 | |

> **`ssl_server_cert_dn` 확인 방법:**
> ```bash
> # DB1 서버에서 실행
> orapki wallet display -wallet /opt/oracle/dcs/commonstore/tcps_wallet
> # 또는
> openssl s_client -connect <db1_host>:<tcps_port> 2>/dev/null | openssl x509 -noout -subject
> ```

#### TCP 접속 (Wallet 불필요)

DB1이 TCP(비암호화) 접속을 허용하는 경우:

```sql
BEGIN
    DBMS_CLOUD.CREATE_DATABASE_LINK(
        db_link_name => 'DB1_LINK',
        hostname     => '<db1_host>',
        port         => 1521,
        service_name => '<db1_service_name>',
        username     => '<db1_user>',
        password     => '<db1_password>'
    );
END;
/
```

### 3.2 방법 2: CREATE DATABASE LINK DDL 사용

ADB에서 DDL을 직접 사용할 수도 있습니다.

```sql
-- ADB에서 실행 (TCPS)
CREATE DATABASE LINK DB1_LINK
    CONNECT TO <db1_user> IDENTIFIED BY "<db1_password>"
    USING '(DESCRIPTION=
             (ADDRESS=(PROTOCOL=TCPS)(PORT=<tcps_port>)
                      (HOST=<db1_host>))
             (CONNECT_DATA=
                (SERVICE_NAME=<db1_service_name>))
             (SECURITY=
                (SSL_SERVER_DN_MATCH=YES)))';
```

```sql
-- ADB에서 실행 (TCP)
CREATE DATABASE LINK DB1_LINK
    CONNECT TO <db1_user> IDENTIFIED BY "<db1_password>"
    USING '(DESCRIPTION=
             (ADDRESS=(PROTOCOL=TCP)(PORT=1521)
                      (HOST=<db1_host>))
             (CONNECT_DATA=
                (SERVICE_NAME=<db1_service_name>)))';
```

---

## 4. 연결 확인

```sql
-- ADB에서 실행

-- 기본 연결 테스트
SELECT * FROM DUAL@DB1_LINK;

-- DB1 테이블 접근 확인
SELECT COUNT(*) FROM dba_tables@DB1_LINK;

-- DB Link 정보 확인
SELECT db_link, username, host FROM user_db_links WHERE db_link = 'DB1_LINK';
```

---

## 5. 네트워크 요구사항

### 5.1 OCI 내부 (같은 VCN)

DB1과 ADB가 같은 VCN에 있으면 Private Endpoint로 직접 통신 가능.

| 항목 | 설정 |
|------|------|
| ADB Private Endpoint | ADB 생성 시 또는 이후 설정 |
| Security List | DB1 서브넷에서 ADB로의 인바운드 허용 (1521/2484) |
| DB1 방화벽 | ADB Private IP에서 오는 접속 허용 |

### 5.2 OCI 내부 (다른 VCN)

VCN 피어링 또는 DRG(Dynamic Routing Gateway)를 통해 연결.

```
ADB (VCN-A) ──── Local Peering ────► DB1 (VCN-B)
```

### 5.3 네트워크 ACL (ADB 아웃바운드)

ADB에서 외부(DB1)로 접속하려면 ACL을 설정해야 합니다.

```sql
-- ADB에서 실행 (ADMIN 유저)
BEGIN
    DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
        host => '<db1_host>',
        ace  => xs$ace_type(
            privilege_list => xs$name_list('connect'),
            principal_name => '<adb_user>',
            principal_type => xs_acl.ptype_db
        )
    );
END;
/
```

---

## 6. Case 4 전용: Standby → Primary DB Link

Case 4(ADG + SQL Tuning Advisor)에서 Standby → Primary DB Link는 별도 구성입니다.
이 DB Link는 ADB가 아닌 **Standby DB1에서 Primary DB로** 향합니다.

```sql
-- Standby DB에서 SYS로 접속하여 실행
-- ★ 반드시 SYS 소유 Private DB Link이어야 함
CREATE DATABASE LINK LNK_TO_PRI
    CONNECT TO SYS$UMF IDENTIFIED BY "<password>"
    USING '(DESCRIPTION=
             (ADDRESS=(PROTOCOL=TCPS)(PORT=<tcps_port>)
                      (HOST=<primary_host>))
             (CONNECT_DATA=
                (SERVICE_NAME=<primary_service_name>))
             (SECURITY=
                (SSL_SERVER_DN_MATCH=YES)
                (MY_WALLET_DIRECTORY=/opt/oracle/primary_wallet)))';
```

| 항목 | 요구사항 |
|------|---------|
| 소유자 | **SYS** (일반유저 불가) |
| 접속 유저 | **SYS$UMF** (Oracle 19c+ 자동 생성) |
| 타입 | **Private** (Public 불가) |
| Wallet | Primary DB의 인증서가 포함된 Wallet |

> **Primary가 TCP 접속을 허용하는 경우:**
> ```sql
> CREATE DATABASE LINK LNK_TO_PRI
>     CONNECT TO SYS$UMF IDENTIFIED BY "<password>"
>     USING '(DESCRIPTION=
>              (ADDRESS=(PROTOCOL=TCP)(PORT=1521)
>                       (HOST=<primary_host>))
>              (CONNECT_DATA=
>                (SERVICE_NAME=<primary_service_name>)))';
> ```

---

## 7. 트러블슈팅

### ORA-29024: Certificate validation failure

```
원인: ADB가 DB1의 서버 인증서(CA)를 신뢰하지 않음
해결:
  1. DB1이 OCI DB System이면 같은 리전 내에서는 기본 신뢰됨
  2. 자체 서명 인증서인 경우 ADB Wallet에 CA 인증서 등록 필요
  3. ssl_server_cert_dn 값이 실제 DB1 인증서 DN과 일치하는지 확인
```

### ORA-12154: TNS:could not resolve the connect identifier

```
원인: TNS 별칭을 찾을 수 없음
해결:
  1. DBMS_CLOUD.CREATE_DATABASE_LINK 사용 시 hostname/service_name 직접 지정
  2. DDL 사용 시 전체 TNS Descriptor를 USING 절에 기술
```

### ORA-12545: Connect failed (target host does not exist)

```
원인: ADB에서 DB1 호스트로 네트워크 연결 불가
해결:
  1. ADB Private Endpoint가 DB1과 같은 VCN/서브넷에 있는지 확인
  2. Security List에서 DB1 포트(1521/2484) 인바운드 허용 확인
  3. DBMS_NETWORK_ACL_ADMIN으로 아웃바운드 ACL 설정 확인
```

### ORA-28759: failure to open file

```
원인: Wallet 파일을 열 수 없음
해결:
  1. DBMS_CLOUD.CREATE_DATABASE_LINK 사용 시 Wallet은 ADB가 내부적으로 관리
  2. DDL 사용 시 MY_WALLET_DIRECTORY 경로에 cwallet.sso가 있는지 확인
```

### ORA-28040: No matching authentication protocol

```
원인: ADB와 DB1 간 인증 프로토콜 불일치
해결:
  1. DB1의 sqlnet.ora에서 SQLNET.ALLOWED_LOGON_VERSION_SERVER 확인
  2. 12 이상으로 설정: SQLNET.ALLOWED_LOGON_VERSION_SERVER=12
```

---

## 8. DB Link 관리

### DB Link 삭제

```sql
-- DBMS_CLOUD로 생성한 경우
BEGIN
    DBMS_CLOUD.DROP_DATABASE_LINK(db_link_name => 'DB1_LINK');
END;
/

-- DDL로 생성한 경우
DROP DATABASE LINK DB1_LINK;
```

### DB Link 목록 확인

```sql
SELECT db_link, username, host FROM user_db_links;
```

### DB Link 연결 종료

```sql
ALTER SESSION CLOSE DATABASE LINK DB1_LINK;
```
