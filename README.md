# db-transaction-lab

동시 갱신 상황에서 트랜잭션 격리수준과 락이 실제로 어떻게 동작하는지 Docker DB로 재현한 실험 기록입니다.

| 실험 | 문서 | 재현 SQL |
|---|---|---|
| Lost update 재현과 해결 (MySQL 8.4 InnoDB, REPEATABLE READ) | [lost-update.md](lost-update.md) | [sql/lost-update.sql](sql/lost-update.sql) |
| 접근 순서 데드락 재현과 해결 (MySQL 8.4 InnoDB, REPEATABLE READ) | [deadlock.md](deadlock.md) | [sql/deadlock.sql](sql/deadlock.sql) |

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

## 재현 방법

재현 SQL은 한 번에 실행하는 스크립트가 아니라 절차서입니다. 터미널 두 개로 각각 접속한 뒤, 주석의 `[S1]`/`[S2]` 표시와 단계 번호 순서대로 실행합니다.
