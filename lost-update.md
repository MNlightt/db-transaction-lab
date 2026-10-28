# 2주차 트랜잭션·락 실험

## 환경

- DB: MySQL 8.4 (Docker)
- 격리수준: REPEATABLE-READ
- 각 실험마다 아래 SQL로 초기화하였음

```sql
CREATE DATABASE IF NOT EXISTS txlab; USE txlab;
DROP TABLE IF EXISTS keyword_stats;
CREATE TABLE keyword_stats (keyword VARCHAR(50) PRIMARY KEY, count INT NOT NULL) ENGINE=InnoDB;
INSERT INTO keyword_stats VALUES ('search', 99);
```

## 시나리오

동시 사용자가 있는 포탈에서 검색어를 집계. 키워드가 카운트가 100되면 hot keyword 선정됨과 동시에 앱을 통해 알림이 감.

---

## 실험 A — 앱에서 계산한 값으로 UPDATE

| 순서 | 세션 1 | 세션 2 |
|---|---|---|
| 1 | `BEGIN; SELECT count FROM keyword_stats WHERE keyword='search';` | |
| 2 | | `BEGIN; SELECT count FROM keyword_stats WHERE keyword='search';` |
| 3 | `UPDATE keyword_stats SET count = 100 WHERE keyword='search';` | |
| 4 | | `UPDATE keyword_stats SET count = 100 WHERE keyword='search';` → 대기하는지 확인 |
| 5 | `COMMIT;` | |
| 6 | | (대기가 풀림) `COMMIT;` |

### 예측

최종 count는 100, 세션 2가 세션 1의 update 때 얻은 x락으로 인해 대기함.

### 결과

- 격리수준: REPEATABLE-READ (세션 1에서 확인)
- 최종 count: 100 (증가 2회 의도 → 1회만 반영, lost update 재현)
- 대기: 세션 2가 4단계 UPDATE에서 대기, 세션 1 COMMIT 후 풀림
  - 근거: `Query OK, 0 rows affected (5.11 sec)`
- 에러: 없음
- 근거: 세션 2 UPDATE `Rows matched: 1  Changed: 0`
  - 행은 찾았지만 이미 100이라 실제로 바뀐 값이 없음. 세션 2의 증가분이 사라진 흔적
- 예측과 비교: 일치 (최종 100, 세션 2 대기)
- 앱 관점 해석: 두 요청 모두 99를 읽고 100을 판단 → 알림 2번

---

## 실험 B — 원자적 UPDATE

| 순서 | 세션 1 | 세션 2 |
|---|---|---|
| 1 | `BEGIN; SELECT count FROM keyword_stats WHERE keyword='search';` | |
| 2 | | `BEGIN; SELECT count FROM keyword_stats WHERE keyword='search';` |
| 3 | `UPDATE keyword_stats SET count = count + 1 WHERE keyword='search';` | |
| 4 | | `UPDATE keyword_stats SET count = count + 1 WHERE keyword='search';` → 대기하는지 확인 |
| 5 | `COMMIT;` | |
| 6 | | (대기가 풀림) `COMMIT;` |

### 예측

최종 count는 101, 세션 2가 세션 1의 update 때 얻은 x락으로 인해 대기함.

### 결과

- 격리수준: REPEATABLE-READ (세션 1에서 확인)
- 최종 count: 101 (증가 2회)
- 대기: 세션 2가 4단계 UPDATE에서 대기, 세션 1 COMMIT 후 풀림
  - 근거: `Query OK, 1 rows affected (7.71 sec)`
- 에러: 없음
- 근거: 세션 2 UPDATE `Rows matched: 1  Changed: 1  Warnings: 0`
  - 행 찾은 뒤 실제 UPDATE 진행됨.
- 예측과 비교: 일치 (최종 101, 세션 2 대기)
- 앱 관점 해석: 두 요청 모두 99를 읽고 100을 판단 → 알림 2번

### 추가 실험

세션 2가 UPDATE한 이후에 COMMIT 전 세션 2에서 다시 조회 쿼리(SELECT count FROM keyword_stats WHERE keyword='search';)를 실행하면 count가 101로 나옴.

- 자기 트랜잭션 내에서 바꾼 내용은 스냅샷 위에 덧씌워짐.

---

## 실험 C — SELECT ... FOR UPDATE

| 순서 | 세션 1 | 세션 2 |
|---|---|---|
| 1 | `BEGIN; SELECT count FROM keyword_stats WHERE keyword='search' FOR UPDATE;` | |
| 2 | | `BEGIN; SELECT count FROM keyword_stats WHERE keyword='search' FOR UPDATE;` |
| 3 | `data_locks`, `data_lock_waits` 조회 | |
| 4 | `UPDATE keyword_stats SET count = count + 1 WHERE keyword='search';` | |
| 5 | `COMMIT;` | |
| 6 | | (대기가 풀림) `UPDATE keyword_stats SET count = count + 1 WHERE keyword='search'; COMMIT;` |

### 예측

hot keyword 알림 1번, 최종 count는 101, 세션 2가 세션 1의 select for update 때 얻은 x락으로 인해 2번 단계에서 대기함.

### 결과

- 격리수준: REPEATABLE-READ (세션 1에서 확인)
- 최종 count: 101 (증가 2회)
- 대기: 세션 2가 2단계 SELECT ... FOR UPDATE에서 대기(1차 시도 타임아웃), 세션 1 COMMIT 후 풀림
  - 근거: `ERROR 1205 (HY000): Lock wait timeout exceeded; try restarting transaction`
- 에러: 락 대기 타임아웃 에러(재시도하여 해결)
- 근거: 세션 2의 조회 쿼리 재시도에서 count 100 반환(SELECT FOR UPDATE가 현재 커밋된 최신값을 읽음)
  - 근거: `count - 100`, `1 row in set (5.60 sec)`
- 예측과 비교: 일치 (최종 101, 세션 2 대기)
- 앱 관점 해석: SELECT FOR UPDATE를 통해 세션 2의 조회 쿼리가 대기하였으므로 알림 1번

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
|                  2397 | TABLE     | IX            | GRANTED     | NULL      |
|                  2398 | TABLE     | IX            | GRANTED     | NULL      |
|                  2397 | RECORD    | X,REC_NOT_GAP | GRANTED     | 'search'  |
|                  2398 | RECORD    | X,REC_NOT_GAP | WAITING     | 'search'  |
+-----------------------+-----------+---------------+-------------+-----------+
4 rows in set (0.01 sec)

*************************** 1. row ***************************
                          ENGINE: INNODB
       REQUESTING_ENGINE_LOCK_ID: 128474084663296:72:7:4:2:128474014605392
REQUESTING_ENGINE_TRANSACTION_ID: 2398
            REQUESTING_THREAD_ID: 51
             REQUESTING_EVENT_ID: 45
REQUESTING_OBJECT_INSTANCE_BEGIN: 0
         BLOCKING_ENGINE_LOCK_ID: 128474084662488:104:7:4:2:128474014599216
  BLOCKING_ENGINE_TRANSACTION_ID: 2397
              BLOCKING_THREAD_ID: 50
               BLOCKING_EVENT_ID: 57
  BLOCKING_OBJECT_INSTANCE_BEGIN: 0
1 row in set (0.03 sec)
```

| 트랜잭션 | 락 | 의미 |
|---|---|---|
| 2397 (세션 1) | TABLE IX GRANTED | 테이블에 "이 안의 행을 X로 잠글 예정"이라는 의도 락. 테이블 전체 락과의 충돌 검사용이라 IX끼리는 충돌하지 않음 (그래서 둘 다 GRANTED) |
| 2398 (세션 2) | TABLE IX GRANTED | 위와 같음 |
| 2397 | RECORD X,REC_NOT_GAP GRANTED 'search' | 세션 1이 'search' 행 하나만 잠금 |
| 2398 | RECORD X,REC_NOT_GAP WAITING 'search' | 세션 2가 같은 행을 기다림 |

REQUESTING_ENGINE_TRANSACTION_ID: 2398(세션 2), BLOCKING_ENGINE_TRANSACTION_ID: 2397(세션 1)

- 세션 1이 세션 2의 조회 쿼리를 막고 있음.

---

## 실험 D — SELECT ... FOR SHARE (잘못된 해결)

| 순서 | 세션 1 | 세션 2 |
|---|---|---|
| 1 | `BEGIN; SELECT count FROM keyword_stats WHERE keyword='search' FOR SHARE;` | |
| 2 | | `BEGIN; SELECT count FROM keyword_stats WHERE keyword='search' FOR SHARE;` |
| 3 | `UPDATE keyword_stats SET count = count + 1 WHERE keyword='search';` → 대기 | |
| 4 | | `UPDATE keyword_stats SET count = count + 1 WHERE keyword='search';` → ERROR 1213 (희생자) |
| 5 | 희생자 세션은 1213을 받고 이미 롤백된 상태라 COMMIT하지 않고, 살아남은 세션은 대기가 풀려 UPDATE가 끝나면 COMMIT | |

### 예측

최종 count는 100, 두 세션이 SELECT FOR SHARE 때 얻은 S락으로 인해 UPDATE 문에서 X락을 획득하지 못 하여 데드락에 빠짐. Inno Db가 한 세션의 트랜잭션을 희생하여 데드락 상태를 해제하며 나머지 트랜잭션만 실행 됨. 세션 2가 UPDATE 시점이 늦으므로 데드락 희생자가 될 것으로 예측

### 결과

- 격리수준: REPEATABLE-READ (세션 1에서 확인)
- 최종 count: 100 (세션 2가 데드락 희생으로 롤백되었으므로 증가 1회)
- 대기: 세션 1이 UPDATE에서 대기, 세션 2가 UPDATE 시도 시 데드락으로 인해 희생
  - 근거: `Query OK, 1 row affected (2.02 sec)`, `ERROR 1213 (40001): Deadlock found when trying to get lock; try restarting transaction`
- 에러: 데드락 에러
- 근거: 데드락 이후에 세션 2에서 조회한 SELECT에서 count 100(세션 2의 트랜잭션이 롤백되었음을 의미)
- 예측과 비교: 일치 (최종 100, 세션 2 데드락 희생)
- 앱 관점 해석: 세션 2의 UPDATE가 데드락으로 인해 실패하였으므로 에러 메세지 반환하고 알림 1번. 하지만 세션 2에서의 업데이트 요청이 사라짐

### 고찰

쿼리: `SHOW ENGINE INNODB STATUS\G` (LATEST DETECTED DEADLOCK 발췌)

```
*** (1) HOLDS THE LOCK(S):
RECORD LOCKS space id 8 page no 4 n bits 72 index PRIMARY of table `txlab`.`keyword_stats` trx id 2422 lock mode S locks rec but not gap
*** (1) WAITING FOR THIS LOCK TO BE GRANTED:
RECORD LOCKS space id 8 page no 4 n bits 72 index PRIMARY of table `txlab`.`keyword_stats` trx id 2422 lock_mode X locks rec but not gap waiting
*** (2) HOLDS THE LOCK(S):
RECORD LOCKS space id 8 page no 4 n bits 72 index PRIMARY of table `txlab`.`keyword_stats` trx id 2423 lock mode S locks rec but not gap
*** (2) WAITING FOR THIS LOCK TO BE GRANTED:
RECORD LOCKS space id 8 page no 4 n bits 72 index PRIMARY of table `txlab`.`keyword_stats` trx id 2423 lock_mode X locks rec but not gap waiting
*** WE ROLL BACK TRANSACTION (2)
```

MySQL thread id 10은 세션 1(TRANSACTION 1), MySQL thread id 11은 세션 2(TRANSACTION 2)
