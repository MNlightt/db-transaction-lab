# 접근 순서 데드락 실험
## 환경

- DB: MySQL 8.4 (Docker)
- 격리수준: REPEATABLE-READ
- 각 실험마다 아래 SQL로 초기화하였음

```sql
USE txlab;
DROP TABLE IF EXISTS keyword_stats;
CREATE TABLE keyword_stats (keyword VARCHAR(50) PRIMARY KEY, count INT NOT NULL) ENGINE=InnoDB;
INSERT INTO keyword_stats VALUES ('news', 50), ('search', 99);
```

---

## 실험 E-1 - 역순 접근 (정렬되지 않은 업데이트)
| 순서 | 세션 1(['search','news']) | 세션 2(['news','search']) |
|---|---|---|
| 1 | `BEGIN; UPDATE keyword_stats SET count = count + 1 WHERE keyword='search';` | |
| 2 | | `BEGIN; UPDATE keyword_stats SET count = count + 1 WHERE keyword='news';` |
| 3 | `UPDATE keyword_stats SET count = count + 1 WHERE keyword='news';` | |
| 4 | | `UPDATE keyword_stats SET count = count + 1 WHERE keyword='search';` |
| 5 | `(살아남은 세션) COMMIT;` | |
| 6 | `SELECT * FROM keyword_stats;` 그리고 `SHOW ENGINE INNODB STATUS\G` | |

### 예측
1. 3단계에서 세션1이 대기. 4단계에서 세션 2가 업데이트 시도할 때 1213 데드락 에러가 나며 트랜잭션 롤백. 롤백할 정보가 적은 세션 2가 희생자.
2. 세션 2에 대한 업데이트가 소실되므로 최종 카운트는 news: 51, search: 100
3. latest deadlock에서 보게 될 lock 모드는 모드 X락. 실험 D에서는 SELECT ... FOR SHARE에서 얻은 S락이 업데이트를 위한 X락을 막았음.

### 결과

- 격리수준: REPEATABLE-READ (세션 1에서 확인)
- 최종 count: news: 51, search: 100. (세션 2가 데드락 희생으로 롤백되었으므로 증가 각 1회)
- 대기: 세션 1이 UPDATE에서 대기, 세션 2가 UPDATE 시도 시 데드락으로 인해 희생
  - 근거: `Query OK, 1 row affected (8.36 sec)`, `ERROR 1213 (40001): Deadlock found when trying to get lock; try restarting transaction`
- 에러: 데드락 에러
- 근거: 데드락 이후에 세션 1에서 조회한 SELECT에서 count 각각 news: 51, search: 100(세션 2의 트랜잭션이 롤백되었음을 의미)
- 예측과 비교: 부분일치 (최종 news:51, search: 100, 세션 2 데드락 희생)
    -> 희생자 근거 불일치: 양쪽 undo log entries 1, 2 row lock(s)로 비용 동일. 관찰상 사이클을 완성한 세션 2가 희생됨
- 비교: 실험 D와의 비교에서 D는 S락을 쥐고 X락 요청, E-1은 X락을 쥐고 X락 요청. D는 같은 행 1개, E-1은 서로 다른 행 2개. D는 락 종류를 바꿔 해결, E-1은 접근순서를 바꿔 해결.

### 고찰

쿼리: `SHOW ENGINE INNODB STATUS\G` (LATEST DETECTED DEADLOCK 발췌)

```
*** (1) HOLDS THE LOCK(S):
RECORD LOCKS space id 9 page no 4 n bits 72 index PRIMARY of table `txlab`.`keyword_stats` trx id 2850 lock_mode X locks rec but not gap
*** (1) WAITING FOR THIS LOCK TO BE GRANTED:
RECORD LOCKS space id 9 page no 4 n bits 72 index PRIMARY of table `txlab`.`keyword_stats` trx id 2850 lock_mode X locks rec but not gap waiting
*** (2) HOLDS THE LOCK(S):
RECORD LOCKS space id 9 page no 4 n bits 72 index PRIMARY of table `txlab`.`keyword_stats` trx id 2851 lock_mode X locks rec but not gap
*** (2) WAITING FOR THIS LOCK TO BE GRANTED:
RECORD LOCKS space id 9 page no 4 n bits 72 index PRIMARY of table `txlab`.`keyword_stats` trx id 2851 lock_mode X locks rec but not gap waiting
*** WE ROLL BACK TRANSACTION (2)
```

MySQL thread id 9은 세션 1(TRANSACTION 1), MySQL thread id 10은 세션 2(TRANSACTION 2)
---

## 실험 E-2 - 정렬 순서( 둘 다 ['news','search'])
| 순서 | 세션 1 | 세션 2 |
|---|---|---|
| 1 | `BEGIN; UPDATE keyword_stats SET count = count + 1 WHERE keyword='news';` | |
| 2 | | `BEGIN; UPDATE keyword_stats SET count = count + 1 WHERE keyword='news';` |
| 3 | `data_locks`, `data_lock_waits` 조회 | |
| 4 | `UPDATE keyword_stats SET count = count + 1 WHERE keyword='search';` | |
| 5 | `COMMIT;` | |
| 6 | | (대기가 풀리면) `UPDATE keyword_stats SET count = count + 1 WHERE keyword='search'; COMMIT;` |
| 7 | `SELECT * FROM keyword_stats;` | |

### 예측
세션 2가 2단계에서 대기. 세션 1의 커밋 이후 대기가 풀림. 최종 카운트는 news: 52, search: 101. 세션 1의 news 레코드 X락이 세션 2의 업데이트를 막음.

### 결과

- 격리수준: REPEATABLE-READ (세션 1에서 확인)
- 최종 count - news: 52, search: 101.
- 대기: 세션 2가 2단계 UPDATE에서 대기, 세션 1 커밋 이후 풀림.
  - 근거: `Query OK, 1 row affected (33.25 sec)`
- 에러: 없음.
- 근거: 대기가 생겼지만, 데드락 상황이 되진 않음.
- 예측과 비교: 일치 (최종 count - news: 52, search: 101)

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
|                  2877 | TABLE     | IX            | GRANTED     | NULL      |
|                  2878 | TABLE     | IX            | GRANTED     | NULL      |
|                  2877 | RECORD    | X,REC_NOT_GAP | GRANTED     | 'news'    |
|                  2878 | RECORD    | X,REC_NOT_GAP | WAITING     | 'news'    |
+-----------------------+-----------+---------------+-------------+-----------+
4 rows in set (0.01 sec)
*************************** 1. row ***************************
                          ENGINE: INNODB
       REQUESTING_ENGINE_LOCK_ID: 132586119815168:86:10:4:2:132586043138128
REQUESTING_ENGINE_TRANSACTION_ID: 2878
            REQUESTING_THREAD_ID: 50
             REQUESTING_EVENT_ID: 18
REQUESTING_OBJECT_INSTANCE_BEGIN: 0
         BLOCKING_ENGINE_LOCK_ID: 132586119814360:94:10:4:2:132586043131952
  BLOCKING_ENGINE_TRANSACTION_ID: 2877
              BLOCKING_THREAD_ID: 49
               BLOCKING_EVENT_ID: 33
  BLOCKING_OBJECT_INSTANCE_BEGIN: 0
1 row in set (0.02 sec)
```

세션 1(2877)이 세션2(2878)의 업데이트를 막고 있음.
실험 E-1과 비교하여 같은 두 행이지만, 순서를 정렬함으로써 데드락->단순 대기 형태로 바꿈.
(추가) 실험에서 수동 커밋으로 인해 33초가 걸렸는데, 50초가 초과됐을 시 lock wait timeout error가 발생했을 것. 트랜잭션을 짧게 유지해야 함.
