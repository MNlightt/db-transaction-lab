# 인덱스 유무와 락 범위 실험 (1주차 실습 4-1/4-2 재실험)
## 환경

- DB: MySQL 8.4 (Docker)
- 격리수준: REPEATABLE-READ
- 각 실험(H-1, H-2)마다 아래 SQL로 초기화하였음

초기화 쿼리:
```sql
USE txlab;
DROP TABLE IF EXISTS keyword_stats_w01;
CREATE TABLE keyword_stats_w01 (
  id INT AUTO_INCREMENT PRIMARY KEY,
  keyword VARCHAR(50) NOT NULL,
  count INT NOT NULL DEFAULT 0) ENGINE=InnoDB;
INSERT INTO keyword_stats_w01 (id, keyword) VALUES
  (1,'search'),(2,'news'),(3,'weather'),(4,'movie'),(5,'stock');
```
1주차 초기화 sql이 남지 않아 결과 파일 출력 기준 재구성

## 시나리오

동시 사용자가 있는 포탈에서 검색어를 집계. 키워드가 카운트가 100되면 hot keyword 선정됨과 동시에 앱을 통해 알림이 감.
---

## 실험 H-1 - 인덱스 없이 UPDATE
| 순서 | 세션 1 | 세션 2 |
|---|---|---|
| 1 | `BEGIN; UPDATE keyword_stats_w01 SET count = count + 1 WHERE keyword='search';` 후 trx_id 확인 | |
| 2 | | `UPDATE keyword_stats_w01 SET count = count + 1 WHERE keyword='weather';` |
| 3 | | `INSERT INTO keyword_stats_w01 (keyword) VALUES ('apple');` |
| 4 | `SELECT index_name, lock_type, lock_mode, lock_status, lock_data FROM performance_schema.data_locks;` 락 조회||
| 5 | `	ROLLBACK;`| |

### 예측
1. 대기함. 세컨더리 인덱스가 없어 S1의 업데이트로 인해 클러스터드 인덱스 전체 레코드를 잠금.
2. PRIMARY, X,REC_AND_GAP,`1`,...,PRIMARY, X,REC_AND_GAP,`5`

### 결과

- 격리수준: REPEATABLE-READ (세션 1에서 확인)
- 대기: 2,3단계에서 세션 2가 대기함.
  - 근거: `ERROR 1205 (HY000): Lock wait timeout exceeded; try restarting transaction`
- 에러: 1205 lock wait timeout error
- 근거: 인덱스가 없어서 S1의 업데이트로 인해 전체 레코드와 supremum까지 X락이 걸림.
- 예측과 비교: 부분 일치 (2,3단계 대기. 1~5 PRIMARY lock)
  -> 락 상태 불일치: X, REC_AND_GAP이란 말은 없음. next-key락은 X락으로 표기. 마지막 레코드의 뒷간격인 supremum이 예측에서 제외됨.
  INSERT의 경우 5와 supremum 사이로 들어가려해서 막힘.

### 고찰

쿼리:

```sql
SELECT engine_transaction_id, lock_type, lock_mode, lock_status, lock_data FROM performance_schema.data_locks;
```

결과:

```
+------------+-----------+-----------+-------------+------------------------+
| index_name | lock_type | lock_mode | lock_status | lock_data              |
+------------+-----------+-----------+-------------+------------------------+
| NULL       | TABLE     | IX        | GRANTED     | NULL                   |
| PRIMARY    | RECORD    | X         | GRANTED     | supremum pseudo-record |
| PRIMARY    | RECORD    | X         | GRANTED     | 1                      |
| PRIMARY    | RECORD    | X         | GRANTED     | 2                      |
| PRIMARY    | RECORD    | X         | GRANTED     | 3                      |
| PRIMARY    | RECORD    | X         | GRANTED     | 4                      |
| PRIMARY    | RECORD    | X         | GRANTED     | 5                      |
+------------+-----------+-----------+-------------+------------------------+
7 rows in set (0.01 sec)
```
인덱스가 없어 S1의 업데이트가 전체 레코드 + supremum까지 잠김.

## 실험 H-2 - 인덱스 생성 후 UPDATE
CREATE INDEX idx_keyword ON keyword_stats_w01(keyword);

| 순서 | 세션 1 | 세션 2 |
|---|---|---|
| 1 | `BEGIN; UPDATE keyword_stats_w01 SET count = count + 1 WHERE keyword='search';` 후 trx_id 확인 | |
| 2 | `SELECT index_name, lock_type, lock_mode, lock_status, lock_data FROM performance_schema.data_locks;` 락 조회||
| 3 | | `UPDATE keyword_stats_w01 SET count = count + 1 WHERE keyword='weather';` |
| 4 | | `INSERT INTO keyword_stats_w01 (keyword) VALUES ('apple');` |
| 5 | | `INSERT INTO keyword_stats_w01 (keyword) VALUES ('rain');` |
| 6 | | `INSERT INTO keyword_stats_w01 (keyword) VALUES ('sports');` |
| 7 | | `INSERT INTO keyword_stats_w01 (keyword) VALUES ('zebra');` |
| 8 | `ROLLBACK;`| |

### 예측
1. PRIMARY, X,REC_NOT_GAP, `1`, idx_keyword, X, `search`,idx_keyword, X,GAP, `stock`
2. 5,6단계만 대기. rain의 경우 news와 search 앞 간격 사이로 들어가는데 현재 S1의 UPDATE로 인해 search의 next-key락이 걸려있음.
  마찬가지로 sports도 search와 stock 앞 간격 사이. stock의 간격이 잠겨있음.

### 결과

- 격리수준: REPEATABLE-READ (세션 1에서 확인)
- 대기: 5,6단계에서 세션 2가 대기함.
  - 근거: `ERROR 1205 (HY000): Lock wait timeout exceeded; try restarting transaction`
- 에러: 1205 lock wait timeout error
- 근거: idx_keyword를 통해 인덱스를 생성하여 S1에서 UPDATE되는 search의 레코드와 앞뒤 간격이 잠김. news와 search 간격 사이 + search와 stock 간격 사이에 해당하는 rain과 sports만 대기.
- 예측과 비교: 일치 (5,6단계 대기. lock종류)

### 고찰

쿼리:

```sql
SELECT engine_transaction_id, lock_type, lock_mode, lock_status, lock_data FROM performance_schema.data_locks;
```

결과:

```
+-------------+-----------+---------------+-------------+-------------+
| index_name  | lock_type | lock_mode     | lock_status | lock_data   |
+-------------+-----------+---------------+-------------+-------------+
| NULL        | TABLE     | IX            | GRANTED     | NULL        |
| idx_keyword | RECORD    | X,GAP         | GRANTED     | 'stock', 5  |
| idx_keyword | RECORD    | X             | GRANTED     | 'search', 1 |
| PRIMARY     | RECORD    | X,REC_NOT_GAP | GRANTED     | 1           |
+-------------+-----------+---------------+-------------+-------------+
4 rows in set (0.00 sec)
```
keyword 컬럼에 인덱스를 생성함으로써 UPDATE되는 search는 next-key락, stock은 레코드 없이 간격만 잠김. 따라서 weather UPDATE와 apple, zebra의 INSERT는 대기 없이 성공.

H-1 실험에서는 모든 레코드가 X락으로 잠긴 데에 비해 인덱스 생성으로 search에 해당하는 범위(search의 레코드와 앞뒤 간격)만 잠김.
