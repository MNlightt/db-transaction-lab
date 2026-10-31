# Lost update MSSQL 비교 실험 (SQL Server 2022)

## 환경

- DB: MSSQL2022 (Docker)
- 격리수준: REPEATABLE-READ
- 각 실험마다 아래 SQL로 초기화하였음

```sql
CREATE DATABASE txlab;
GO
USE txlab;
DROP TABLE IF EXISTS keyword_stats;
CREATE TABLE keyword_stats (keyword VARCHAR(50) PRIMARY KEY, count INT NOT NULL);
INSERT INTO keyword_stats VALUES ('search', 99);
GO
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
GO
```
- 각 세션에서 SET TRANSACTION ISOLATION LEVEL REPEATABLE READ; 호출하여 격리수준 조정.

## 시나리오

동시 사용자가 있는 포탈에서 검색어를 집계. 키워드가 카운트가 100되면 hot keyword 선정됨과 동시에 앱을 통해 알림이 감.

---

## 실험 G-1 — 앱에서 계산한 값으로 UPDATE
| 순서 | 세션 1 | 세션 2 |
|---|---|---|
| 1 | `BEGIN TRAN; SELECT count FROM keyword_stats WHERE keyword='search';` | |
| 2 | | `BEGIN TRAN; SELECT count FROM keyword_stats WHERE keyword='search';` |
| 3 | `UPDATE keyword_stats SET count = 100 WHERE keyword='search';` | |
| 4 | | 락 조회 |
| 5 | | `UPDATE keyword_stats SET count = 100 WHERE keyword='search';` |
| 6 | (살아남은 세션) `COMMIT;` | |

### 예측
1. 대기함. S1과 S2가 각각 SELECT를 호출하여 레코드에 S락을 잡았음. UPDATE를 위한 X락을 얻기 위해 대기. MySQL실험 A에서는 대기 없이 UPDATE 진행됨.
2. 대기 없이 업데이트 진행됨.
3. 최종 count 100. 세션 1의 업데이트가 소실됨.
4. IS, GRANT, IX, WAIT

### 결과

- 격리수준: SET TRANSACTION ISOLATION LEVEL REPEATABLE READ로 양쪽 세션 지정
- 최종 count: 100 (S1이 데드락 희생자로 인해 업데이트 진행하지 못 함.)
- 대기: S1이 3단계 UPDATE 호출 시 대기.
  - 근거: SPID 73 CONVERT STATUS로 X락을 얻고자 대기. S2의 S락 때문에 대기함.
- 에러: 1205 데드락.
- 근거: Msg 1205, Level 13, State 51, Server 3810dde38e63, Line 1
Transaction (Process ID 73) was deadlocked on lock resources with another process and has been chosen as the deadlock victim. Rerun the transaction.
- 예측과 비교: 부분 일치 (최종 100)
  -> UPDATE 진행 단계: 대기 없이 진행되는 것이 아닌 데드락 희생자가 발생하면서 UPDATE 진행.
  -> 업데이트의 소실 X: 업데이트가 진행되고 그 값이 소실되는 것이 아님. 데드락으로 인해 업데이트 진행되지 않음.
  -> 락 대기 상태: S1은 S락(GRANT) + X락(CONVERT), S2는 S락(GRANT)
- 앱 관점 해석: MySQL과 다르게 lost update가 진행되지 않고, 직접 에러 메세지를 받음. 재시도 로직을 넣는다면 101로 정상 업데이트 가능.

### 고찰

쿼리:

```sql
SELECT request_session_id, resource_type, resource_description, request_mode, request_status
FROM sys.dm_tran_locks
WHERE resource_database_id = DB_ID('txlab')
ORDER BY request_session_id;
GO
```

결과:

```
request_session_id resource_type                                                resource_description                                                                                     
                                                                                                                                                        request_mode                     
                            request_status
------------------ ------------------------------------------------------------ ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- ------------------------------------------------------------ ------------------------------------------------------------
                73 DATABASE                                                                                                                                                              
                                                                                                                                                        S                                
                            GRANT
                73 PAGE                                                         1:456                                                                                                    
                                                                                                                                                        IX                               
                            GRANT
                73 KEY                                                          (da94926c78be)                                                                                                                                                                                                                                                   S                                                            GRANT
                73 KEY                                                          (da94926c78be)                                                                                                                                                                                                                                                   X                                                            CONVERT
                73 OBJECT                                                                                                                                                                                                                                                                                                                        IX                                                           GRANT
                74 DATABASE                                                                                                                                                                                                                                                                                                                      S                                                            GRANT
                74 OBJECT                                                                                                                                                                                                                                                                                                                        IS                                                           GRANT
                74 KEY                                                          (da94926c78be)                                                                                                                                                                                                                                                   S                                                            GRANT
                74 PAGE                                                         1:456                                                                                                                                                                                                                                                            IS                                                           GRANT

(9 rows affected)
```

key 행에서 S1(73)은 S락을 가지고 있고(GRANT), X락을 얻고자 대기함(CONVERT). S2(74)는 S락을 가지고 있음(GRANT)
S1에서 UPDATE를 호출할 때 S2의 S락 때문에 대기하고, S2에서 UPDATE를 호출하자 S1의 S락 때문에 대기하는 사이클이 만들어짐. 데드락으로 인한 트랜잭션 롤백(이번의 경우 S1으로 관찰).
MySQL D·E에서는 사이클을 완성한 세션이, SQL Server G-1에서는 먼저 대기한 S1이 희생됨(관찰, 선택 기준 미확인).

RR에서 일반 SELECT가 SQL Server는 S 락을 커밋까지 유지하고, InnoDB는 락 없는 스냅샷 읽기다. 그래서 같은 '읽고 계산해서 쓰기'가 InnoDB에서는 조용한 lost update, SQL Server에서는 1205 데드락(한쪽 실패, 재시도 가능)으로 끝난다.
에러 번호 주의: 같은 1205가 SQL Server에서는 데드락, MySQL에서는 락 대기 타임아웃이다. MySQL의 데드락은 1213.
