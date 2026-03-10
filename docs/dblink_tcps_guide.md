# DB Link 생성 가이드 (TCPS / Wallet 기반)

> DB1에서 ADB(Autonomous Database)로의 DB Link 생성 절차.
> ADB는 TCPS(TLS) 접속만 허용하므로 Wallet 설정이 필수.

---

## 1. 사전 준비

### 1.1 ADB Wallet 다운로드

OCI Console 또는 CLI에서 ADB Client Wallet을 다운로드합니다.

**OCI Console:**
```
ADB 상세 페이지 → Database connection → Download wallet
```

**OCI CLI:**
```bash
oci db autonomous-database generate-wallet \
  --autonomous-database-id <ADB_OCID> \
  --file Wallet_<DB명>.zip \
  --password <wallet_password>
```

Wallet ZIP 파일 내용:
```
Wallet_<DB명>/
├── cwallet.sso          ← Auto-login wallet (핵심)
├── ewallet.p12          ← PKCS#12 wallet
├── tnsnames.ora         ← TNS 별칭 정의
├── sqlnet.ora           ← 네트워크 설정
├── keystore.jks         ← Java KeyStore
├── truststore.jks       ← Java TrustStore
└── ojdbc.properties     ← JDBC 설정
```

### 1.2 Wallet을 DB1 서버에 업로드

DB1 서버의 Oracle이 접근 가능한 경로에 Wallet 파일을 배치합니다.

```bash
# DB1 서버에서 실행 (oracle 유저)
mkdir -p /opt/oracle/adb_wallet
cd /opt/oracle/adb_wallet

# Wallet ZIP 업로드 후 압축 해제
unzip Wallet_<DB명>.zip

# 권한 설정 (oracle 유저만 접근)
chmod 700 /opt/oracle/adb_wallet
chmod 600 /opt/oracle/adb_wallet/*

# 파일 확인
ls -la /opt/oracle/adb_wallet/
```

> **OCI Object Storage 경유 시:**
> ```bash
> # Object Storage에서 다운로드 (OCI CLI)
> oci os object get \
>   --bucket-name <bucket> \
>   --name Wallet_<DB명>.zip \
>   --file /opt/oracle/adb_wallet/Wallet.zip
> unzip /opt/oracle/adb_wallet/Wallet.zip -d /opt/oracle/adb_wallet/
> ```

### 1.3 Wallet 경로 확인

DB Link 생성 시 사용할 경로를 확인합니다.

```bash
# cwallet.sso 파일이 있는 디렉토리 경로
ls /opt/oracle/adb_wallet/cwallet.sso
```

이 경로가 아래 `MY_WALLET_DIRECTORY` 값이 됩니다.

---

## 2. DB Link 생성

### 2.1 방법 1: TNS Descriptor 직접 지정 (권장)

DB1 서버의 `tnsnames.ora`를 수정하지 않고, DB Link에 전체 TNS 정보를 직접 기술합니다.

```sql
-- DB1에서 실행 (SYS 또는 권한이 있는 유저)
CREATE DATABASE LINK ADB_LINK
    CONNECT TO <adb_user> IDENTIFIED BY "<adb_password>"
    USING '(DESCRIPTION=
             (RETRY_COUNT=20)(RETRY_DELAY=3)
             (ADDRESS=(PROTOCOL=TCPS)(PORT=1522)
                      (HOST=adb.<region>.oraclecloud.com))
             (CONNECT_DATA=
                (SERVICE_NAME=<고유ID>_<DB명>_medium.adb.oraclecloud.com))
             (SECURITY=
                (SSL_SERVER_DN_MATCH=YES)
                (MY_WALLET_DIRECTORY=/opt/oracle/adb_wallet)))';
```

> **SERVICE_NAME 확인**: Wallet ZIP에 포함된 `tnsnames.ora`에서 원하는 서비스(high/medium/low)의 `service_name` 값을 복사하세요.

**핵심 항목:**

| 항목 | 값 | 설명 |
|------|---|------|
| `PROTOCOL` | `TCPS` | TLS 암호화 통신 (ADB 필수) |
| `PORT` | `1522` | ADB 기본 TCPS 포트 |
| `HOST` | `adb.<region>.oraclecloud.com` | ADB 리전별 호스트 |
| `SERVICE_NAME` | `<고유ID>_<DB명>_<서비스>.adb.oraclecloud.com` | Wallet의 tnsnames.ora에서 확인 |
| `SSL_SERVER_DN_MATCH` | `YES` | 서버 인증서 DN 검증 |
| `MY_WALLET_DIRECTORY` | `/opt/oracle/adb_wallet` | **cwallet.sso가 있는 서버 경로** |

> **`MY_WALLET_DIRECTORY`**: DB Link 전용 Wallet 경로 지정. `sqlnet.ora`의 `WALLET_LOCATION`과 독립적으로 동작하므로, 기존 TDE/TCPS Wallet에 영향 없음.

### 2.2 방법 2: tnsnames.ora 등록 + TNS 별칭 사용

DB1 서버의 `tnsnames.ora`에 ADB 항목을 추가한 후, 별칭으로 DB Link를 생성합니다.

**Step 1: tnsnames.ora에 추가**

```bash
# DB1 서버에서 실행 (oracle 유저)
vi $ORACLE_HOME/network/admin/tnsnames.ora
```

Wallet의 `tnsnames.ora` 내용을 복사하되, `MY_WALLET_DIRECTORY`를 추가:

```
ADB_MEDIUM =
  (DESCRIPTION=
    (RETRY_COUNT=20)(RETRY_DELAY=3)
    (ADDRESS=(PROTOCOL=TCPS)(PORT=1522)
             (HOST=adb.ap-seoul-1.oraclecloud.com))
    (CONNECT_DATA=
      (SERVICE_NAME=<고유ID>_<DB명>_medium.adb.oraclecloud.com))
    (SECURITY=
      (SSL_SERVER_DN_MATCH=YES)
      (MY_WALLET_DIRECTORY=/opt/oracle/adb_wallet)))
```

**Step 2: DB Link 생성**

```sql
CREATE DATABASE LINK ADB_LINK
    CONNECT TO admin IDENTIFIED BY "<adb_password>"
    USING 'ADB_MEDIUM';
```

### 2.3 방법 3: sqlnet.ora의 WALLET_LOCATION 사용

`sqlnet.ora`에 Wallet 경로를 설정하면 `MY_WALLET_DIRECTORY` 없이도 동작합니다.

> **주의**: 기존 TDE/TCPS Wallet 설정과 충돌할 수 있음. 방법 1을 권장.

```bash
# DB1 서버 $ORACLE_HOME/network/admin/sqlnet.ora
WALLET_LOCATION =
  (SOURCE =
    (METHOD = FILE)
    (METHOD_DATA =
      (DIRECTORY = /opt/oracle/adb_wallet)))

SSL_SERVER_DN_MATCH = YES
```

```sql
-- MY_WALLET_DIRECTORY 없이 DB Link 생성
CREATE DATABASE LINK ADB_LINK
    CONNECT TO admin IDENTIFIED BY "<adb_password>"
    USING '(DESCRIPTION=
             (ADDRESS=(PROTOCOL=TCPS)(PORT=1522)
                      (HOST=adb.ap-seoul-1.oraclecloud.com))
             (CONNECT_DATA=
                (SERVICE_NAME=<고유ID>_<DB명>_medium.adb.oraclecloud.com))
             (SECURITY=(SSL_SERVER_DN_MATCH=YES)))';
```

---

## 3. 연결 확인

```sql
-- 기본 연결 테스트
SELECT * FROM DUAL@ADB_LINK;

-- ADB 테이블 접근 확인
SELECT COUNT(*) FROM ai_analysis_request@ADB_LINK;

-- DB Link 정보 확인
SELECT db_link, username, host FROM user_db_links WHERE db_link = 'ADB_LINK';
```

---

## 4. Case 4 전용: Standby → Primary DB Link (TCPS)

Case 4(ADG + SQL Tuning Advisor)에서 Standby → Primary DB Link도 TCPS를 사용하는 경우:

```sql
-- Standby DB에서 SYS로 접속하여 실행
-- ★ 반드시 SYS 소유 Private DB Link이어야 함
CREATE DATABASE LINK LNK_TO_PRI
    CONNECT TO SYS$UMF IDENTIFIED BY "<password>"
    USING '(DESCRIPTION=
             (ADDRESS=(PROTOCOL=TCPS)(PORT=1522)
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

> **Primary가 TCPS가 아닌 TCP 접속을 허용하는 경우:**
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

## 5. mTLS vs TLS-only

ADB는 두 가지 TLS 모드를 지원합니다:

| 모드 | Wallet 필요 | 설정 |
|------|------------|------|
| **mTLS** (기본) | **필요** — 클라이언트 인증서 검증 | 이 문서의 모든 방법 해당 |
| **TLS-only** | **불필요** — 서버 인증서만 검증 | ADB 설정에서 "Require mTLS" 해제 |

### TLS-only 모드로 변경 시

ADB Console에서 `Require mutual TLS (mTLS) authentication`을 해제하면 Wallet 없이 접속 가능:

```sql
-- MY_WALLET_DIRECTORY 없이, 일반 TCPS로 접속
CREATE DATABASE LINK ADB_LINK
    CONNECT TO admin IDENTIFIED BY "password"
    USING '(DESCRIPTION=
             (ADDRESS=(PROTOCOL=TCPS)(PORT=1522)
                      (HOST=adb.ap-seoul-1.oraclecloud.com))
             (CONNECT_DATA=
                (SERVICE_NAME=<service_name>.adb.oraclecloud.com))
             (SECURITY=(SSL_SERVER_DN_MATCH=YES)))';
```

> **주의**: DB1 서버에 Oracle의 기본 CA 인증서(DigiCert 등)가 설치되어 있어야 합니다.

---

## 6. 트러블슈팅

### ORA-29024: Certificate validation failure

```
원인: Wallet에 ADB의 서버 인증서(CA)가 없음
해결:
  1. ADB 전용 Wallet을 사용하는지 확인 (DB1 자체 TDE Wallet과 혼동하지 않기)
  2. MY_WALLET_DIRECTORY가 ADB Wallet 경로를 정확히 가리키는지 확인
  3. cwallet.sso 파일이 oracle 유저로 읽기 가능한지 확인
```

### ORA-12154: TNS:could not resolve the connect identifier

```
원인: TNS 별칭을 찾을 수 없음
해결:
  1. 방법 1(TNS Descriptor 직접 지정)을 사용하면 tnsnames.ora 불필요
  2. 방법 2 사용 시 $ORACLE_HOME/network/admin/tnsnames.ora에 항목이 있는지 확인
  3. TNS_ADMIN 환경변수가 올바른 디렉토리를 가리키는지 확인
```

### ORA-28759: failure to open file

```
원인: Wallet 파일을 열 수 없음
해결:
  1. MY_WALLET_DIRECTORY 경로가 정확한지 확인
  2. 해당 디렉토리에 cwallet.sso 파일이 있는지 확인
  3. oracle 유저에 읽기 권한이 있는지 확인:
     chmod 600 /opt/oracle/adb_wallet/cwallet.sso
     chown oracle:oinstall /opt/oracle/adb_wallet/cwallet.sso
```

### ORA-12545: Connect failed because target host or object does not exist

```
원인: ADB 호스트에 네트워크 연결 불가
해결:
  1. DB1 서버에서 ADB 호스트로 TCPS 포트(1522) 접근 가능한지 확인:
     curl -v telnet://adb.ap-seoul-1.oraclecloud.com:1522
  2. 방화벽/Security List에서 1522 아웃바운드 허용 확인
  3. Private Endpoint 사용 시 VCN 피어링/라우팅 확인
```

### ORA-02085: database link connects to ... (loopback)

```
원인: DB Link가 자기 자신을 가리킴 (동일 DB)
해결:
  1. SERVICE_NAME이 실제 ADB의 서비스명인지 확인 (DB1 서비스명과 혼동하지 않기)
  2. HOST가 ADB 호스트인지 확인
```

---

## 7. DB Link 관리

### DB Link 삭제 후 재생성

```sql
-- 기존 DB Link 삭제
DROP DATABASE LINK ADB_LINK;

-- 재생성
CREATE DATABASE LINK ADB_LINK ...;
```

### DB Link 목록 확인

```sql
-- 현재 유저의 DB Link
SELECT db_link, username, host FROM user_db_links;

-- 전체 DB Link (DBA 권한 필요)
SELECT owner, db_link, username, host FROM dba_db_links;
```

### DB Link 연결 종료

```sql
-- 열린 DB Link 세션 닫기
ALTER SESSION CLOSE DATABASE LINK ADB_LINK;
```
