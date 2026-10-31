# db-transaction-lab

동시 갱신 상황에서 트랜잭션 격리수준과 락이 실제로 어떻게 동작하는지 Docker DB로 재현한 실험 기록입니다.

| 실험 | 문서 | 재현 SQL |
|---|---|---|
| Lost update 재현과 해결 (MySQL 8.4 InnoDB, REPEATABLE READ) | [lost-update.md](lost-update.md) | [sql/lost-update.sql](sql/lost-update.sql) |
| 접근 순서 데드락 재현과 해결 (MySQL 8.4 InnoDB, REPEATABLE READ) | [deadlock.md](deadlock.md) | [sql/deadlock.sql](sql/deadlock.sql) |
| Hot row 대기와 샤딩 (MySQL 8.4 InnoDB, REPEATABLE READ) | [hot-row.md](hot-row.md) | [sql/hot-row.sql](sql/hot-row.sql) |
| Lost update SQL Server 비교 (SQL Server 2022, REPEATABLE READ) | [mssql-lost-update.md](mssql-lost-update.md) | [sql/mssql-lost-update.sql](sql/mssql-lost-update.sql) |

## Lost update 실험 요약

검색어 카운트가 100이 되면 알림을 보내는 시나리오에서, 두 세션이 동시에 카운트를 올릴 때 결과를 비교했습니다.

| 방식 | 결과 | 근거 |
|---|---|---|
| 앱에서 계산한 값으로 UPDATE | 증가 2회 중 1회 소실 | 두 번째 UPDATE `Changed: 0` |
| 원자적 UPDATE (`count = count + 1`) | 정상 반영 | 최종 값 101 |
| `SELECT ... FOR UPDATE` | 정상 반영, 두 번째 조회가 대기 후 최신 값을 읽음 | `data_locks`의 `X,REC_NOT_GAP` GRANTED / WAITING |
| `SELECT ... FOR SHARE` | 데드락(1213), 희생 트랜잭션 전체 롤백 | `SHOW ENGINE INNODB STATUS`: 양쪽 S 보유, X 대기 |

## 접근 순서 데드락 실험 요약

두 세션이 같은 두 행(`news`, `search`)을 각각 한 트랜잭션에서 갱신할 때, 접근 순서에 따라 결과를 비교했습니다.

| 방식 | 결과 | 근거 |
|---|---|---|
| 역순 접근 (`search→news` / `news→search`) | 데드락(1213), 희생 트랜잭션 롤백 | `SHOW ENGINE INNODB STATUS`: 서로 다른 행의 X 보유, 상대 행 X 대기 |
| 정렬 순서 접근 (둘 다 `news→search`) | 데드락 없음, 한쪽이 대기 후 진행 | `data_lock_waits`: 대기 1건, 최종 값 news 52 / search 101 |

정렬은 데드락을 단순 대기로 바꿀 뿐 대기를 없애지는 않으므로, 트랜잭션을 짧게 유지하는 것과 1213 재시도 로직이 함께 필요합니다.

## Hot row 실험 요약

한 행(`search`)에 여러 세션의 쓰기가 몰릴 때와, 같은 값을 샤드 행으로 나눴을 때를 비교했습니다.

| 방식 | 결과 | 근거 |
|---|---|---|
| 한 행에 3세션이 긴 트랜잭션으로 UPDATE | 데드락 없이 줄을 서서 대기, 세 번째 세션은 락 대기 타임아웃(1205), 증가 3회 중 2회만 반영 | `data_lock_waits` 3행(대기 중인 앞 요청도 blocking으로 표시), 두 번째 세션 41.33초 대기 |
| `(keyword, shard_id)` 샤드 행으로 분산 | 대기 없음, 합계 정상 | `data_locks`에 서로 다른 레코드의 `X,REC_NOT_GAP` 2개 GRANTED, `data_lock_waits` 비어 있음 |

1205는 트랜잭션이 아니라 문장만 취소하므로(1205 이후에도 `innodb_trx`에 트랜잭션이 남아 있음) 앱이 직접 롤백해야 합니다. 샤딩의 대가는 읽기가 `SUM`이 되고, "정확히 100에서 한 번 알림" 같은 조건 판정에 별도 장치가 필요하다는 점입니다.

## SQL Server 비교 요약

Lost update 실험의 첫 번째 방식(앱에서 계산한 값으로 UPDATE)을 SQL Server 2022 REPEATABLE READ에서 같은 순서로 실행했습니다.

| DB | 결과 | 근거 |
|---|---|---|
| MySQL InnoDB | 두 세션 모두 성공, 증가분 하나가 조용히 사라짐 | 두 번째 UPDATE `Changed: 0` |
| SQL Server | 데드락, 한쪽이 1205로 실패(재시도 가능) | `sys.dm_tran_locks` KEY: 세션 1 `S` GRANT + `X` CONVERT, 세션 2 `S` GRANT |

차이의 원인은 REPEATABLE READ에서의 일반 SELECT입니다. SQL Server는 S 락을 커밋까지 유지하고, InnoDB는 락 없이 스냅샷을 읽습니다. 같은 1205라도 SQL Server에서는 데드락, MySQL에서는 락 대기 타임아웃을 뜻합니다.

## 재현 방법

재현 SQL은 한 번에 실행하는 스크립트가 아니라 절차서입니다. 터미널 두 개로 각각 접속한 뒤, 주석의 `[S1]`/`[S2]` 표시와 단계 번호 순서대로 실행합니다.
