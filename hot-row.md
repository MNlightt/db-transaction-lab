# hot row 실험
## 환경

- DB: MySQL 8.4 (Docker)
- 격리수준: REPEATABLE-READ
- 각 실험마다 아래 SQL로 초기화하였음

F1 초기화 쿼리:
```sql
USE txlab;
DROP TABLE IF EXISTS keyword_stats;
CREATE TABLE keyword_stats (keyword VARCHAR(50) PRIMARY KEY, count INT NOT NULL) ENGINE=InnoDB;
INSERT INTO keyword_stats VALUES ('search', 99);
```
F2 초기화 쿼리:
```sql
USE txlab;
DROP TABLE IF EXISTS keyword_stats_shard;
CREATE TABLE keyword_stats_shard (
  keyword VARCHAR(50) NOT NULL, shard_id TINYINT NOT NULL, count INT NOT NULL,
  PRIMARY KEY (keyword, shard_id)) ENGINE=InnoDB;
INSERT INTO keyword_stats_shard VALUES ('search',0,99),('search',1,0),('search',2,0),('search',3,0);
```
## 시나리오

동시 사용자가 있는 포탈에서 검색어를 집계. 키워드가 카운트가 100되면 hot keyword 선정됨과 동시에 앱을 통해 알림이 감.
---

## 실험 F-1 - 한 행에 쓰기 몰림 (긴 트랜잭션)
| 순서 | 세션 1 | 세션 2 | 세션 3 |
|---|---|---|---|
| 1 | `BEGIN; UPDATE keyword_stats SET count = count + 1 WHERE keyword='search';` 후 trx_id 확인 | | |
| 2 | | `BEGIN; UPDATE keyword_stats SET count = count + 1 WHERE keyword='search';` 후 trx_id 확인 | |
| 3 | | |`SET SESSION innodb_lock_wait_timeout = 30;BEGIN; UPDATE keyword_stats SET count = count + 1 WHERE keyword='search';` 후 trx_id 확인 |
| 4 | `data_locks`, `data_lock_waits` 조회 | | |
| 5 | | | 30초 뒤 결과 확인 후 SELECT count FROM keyword_stats WHERE keyword='search'; 다음 ROLLBACK; |
| 6 |COMMIT; | | |
| 7 | | 대기 풀리면 COMMIT; | |
| 8 | SELECT * FROM keyword_stats; | | |

### 예측
1. 3행. S1에만 막힌 것으로
2. 이전 COMMIT 값인 99 반환. S3의 트랜잭션은 아직 열려있음.
3. 101. S1과 S2 업데이트 모두 일어남.

### 결과

- 격리수준: REPEATABLE-READ (세션 1에서 확인)
- 최종 count: 101 (S3의 세션은 타임아웃 이후에 UPDATE문 취소. 이후 ROLLBACK;으로 수동 롤백 트랜잭션 종료. S1과 S2의 업데이트만 진행됨. 3회 증가를 의도했지만 실제는 2회만 진행됨.)
- 대기: 세션 2이 UPDATE에서 대기, 세션 3가 UPDATE에서 대기하다 타임아웃
  - 근거: `[Session 2] Query OK, 1 row affected (41.33 sec)`, `[Session3] ERROR 1205 (HY000): Lock wait timeout exceeded; try restarting transaction`
- 에러: 타임아웃 에러
- 근거: S3은 타임아웃 에러 이후에도 트랜잭션이 열린 상태라 trx_id(3420)를 반환. S1,S2의 커밋 이전이므로 SELECT는 99값을 반환.
- 예측과 비교: 부분 일치 (최종 101, 세션 3의 트랜잭션 상태)
  -> 락 상태 불일치: 3행은 맞췄지만, 이유가 불일치. 실제로는 S1, S2가 모두 S3의 업데이트를 막음.
- 앱 관점 해석: 데드락 없이도 대기가 길면 1205로 실패. 해결은 짧은 트랜잭션과 샤딩(hot keyword 알람 유의)

### 고찰

쿼리:

```sql
SELECT engine_transaction_id, lock_type, lock_mode, lock_status, lock_data FROM performance_schema.data_locks;
SELECT * FROM performance_schema.data_lock_waits\G
```

결과:

```
+-----------------------+-----------+---------------+-------------+-----------+
| engine_transaction_id | lock_type | lock_mode     | lock_status | lock_data |
+-----------------------+-----------+---------------+-------------+-----------+
|                  3416 | TABLE     | IX            | GRANTED     | NULL      |
|                  3419 | TABLE     | IX            | GRANTED     | NULL      |
|                  3420 | TABLE     | IX            | GRANTED     | NULL      |
|                  3416 | RECORD    | X,REC_NOT_GAP | GRANTED     | 'search'  |
|                  3419 | RECORD    | X,REC_NOT_GAP | WAITING     | 'search'  |
|                  3420 | RECORD    | X,REC_NOT_GAP | WAITING     | 'search'  |
+-----------------------+-----------+---------------+-------------+-----------+
6 rows in set (0.00 sec)
*************************** 1. row ***************************
                          ENGINE: INNODB
       REQUESTING_ENGINE_LOCK_ID: 131150135566336:94:13:4:2:131150047666256
REQUESTING_ENGINE_TRANSACTION_ID: 3419
            REQUESTING_THREAD_ID: 56
             REQUESTING_EVENT_ID: 21
REQUESTING_OBJECT_INSTANCE_BEGIN: 0
         BLOCKING_ENGINE_LOCK_ID: 131150135565528:112:13:4:2:131150047660080
  BLOCKING_ENGINE_TRANSACTION_ID: 3416
              BLOCKING_THREAD_ID: 55
               BLOCKING_EVENT_ID: 50
  BLOCKING_OBJECT_INSTANCE_BEGIN: 0
*************************** 2. row ***************************
                          ENGINE: INNODB
       REQUESTING_ENGINE_LOCK_ID: 131150135567144:12:13:4:2:131150047672240
REQUESTING_ENGINE_TRANSACTION_ID: 3420
            REQUESTING_THREAD_ID: 57
             REQUESTING_EVENT_ID: 24
REQUESTING_OBJECT_INSTANCE_BEGIN: 0
         BLOCKING_ENGINE_LOCK_ID: 131150135565528:112:13:4:2:131150047660080
  BLOCKING_ENGINE_TRANSACTION_ID: 3416
              BLOCKING_THREAD_ID: 55
               BLOCKING_EVENT_ID: 50
  BLOCKING_OBJECT_INSTANCE_BEGIN: 0
*************************** 3. row ***************************
                          ENGINE: INNODB
       REQUESTING_ENGINE_LOCK_ID: 131150135567144:12:13:4:2:131150047672240
REQUESTING_ENGINE_TRANSACTION_ID: 3420
            REQUESTING_THREAD_ID: 57
             REQUESTING_EVENT_ID: 24
REQUESTING_OBJECT_INSTANCE_BEGIN: 0
         BLOCKING_ENGINE_LOCK_ID: 131150135566336:94:13:4:2:131150047666256
  BLOCKING_ENGINE_TRANSACTION_ID: 3419
              BLOCKING_THREAD_ID: 56
               BLOCKING_EVENT_ID: 21
  BLOCKING_OBJECT_INSTANCE_BEGIN: 0
3 rows in set (0.00 sec)
```

S3(3420)의 UPDATE REQUEST를 S1(3416)과 S2(3419) 모두 막고 있음.(대기 중인 S2의 요청도 blocking으로 표시됨, 관찰)

## 실험 F-2 - 샤드 분산
| 순서 | 세션 1 | 세션 2 |
|---|---|---|
| 1 | `BEGIN; UPDATE keyword_stats_shard SET count = count + 1 WHERE keyword='search' AND shard_id=0;` | |
| 2 | | `BEGIN; UPDATE keyword_stats_shard SET count = count + 1 WHERE keyword='search' AND shard_id=1;` |
| 3 | `data_locks`, `data_lock_waits` 조회 | |
| 4 | COMMIT;	| COMMIT; |
| 5 | `SELECT SUM(count) FROM keyword_stats_shard WHERE keyword='search';` | |

### 예측
샤드 id가 다르므로 대기는 일어나지 않음. data_locks에는 테이블 IX락만 보임. 최종 SUM 101.

### 결과

- 격리수준: REPEATABLE-READ (세션 1에서 확인)
- 최종 count: 101 (샤딩을 통해 서로의 UPDATE가 대기 없이 진행됨.)
- 대기: 없음.
  - 근거: data_lock_waits 결과에 blocking되는 요청들이 나타나지 않음.
- 에러: 없음.
- 근거: S1과 S2는 각각 샤드 id가 다른 UPDATE이기 때문에 서로를 막지 않음. 대기 없이 UPDATE 진행 후 SUM은 101로 의도한 2회 업데이트 진행됨.
- 예측과 비교: 부분 일치 (최종 101, 대기 없음.)
  -> 락 상태 불일치: 테이블 락 뿐만이 아니라 열린 트랜잭션에서의 업데이트가 레코드락을 각각 1회 씩 유발함.
- 앱 관점 해석: 샤딩을 통해 hot row 대기를 해결가능하다. 다만 읽기를 SUM으로 대체해야 하므로 비용이 비싸짐. hot keyword 알람을 위해 플래그행 조건부 UPDATE 등의 별도 작업이 필요.

### 고찰

쿼리:

```sql
SELECT engine_transaction_id, lock_type, lock_mode, lock_status, lock_data FROM performance_schema.data_locks;
SELECT * FROM performance_schema.data_lock_waits\G
```

결과:

```
+-----------------------+-----------+---------------+-------------+-------------+
| engine_transaction_id | lock_type | lock_mode     | lock_status | lock_data   |
+-----------------------+-----------+---------------+-------------+-------------+
|                  3453 | TABLE     | IX            | GRANTED     | NULL        |
|                  3454 | TABLE     | IX            | GRANTED     | NULL        |
|                  3454 | RECORD    | X,REC_NOT_GAP | GRANTED     | 'search', 1 |
|                  3453 | RECORD    | X,REC_NOT_GAP | GRANTED     | 'search', 0 |
+-----------------------+-----------+---------------+-------------+-------------+
4 rows in set (0.00 sec)
Empty set (0.00 sec)
```

레코드락이 샤딩을 통해 분산되었음. 서로의 UPDATE를 막지 않는다는 사실을 두 번째 쿼리 결과가 없으므로 증명.
F-1 실험과 비교하여 결과적으로 같은 증가 2회지만 F-1은 41.33초 대기, F-2는 대기 0.
