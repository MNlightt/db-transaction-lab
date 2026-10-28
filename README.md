# db-transaction-lab

동시 갱신 상황에서 트랜잭션 격리수준과 락이 실제로 어떻게 동작하는지 Docker DB로 재현한 실험 기록입니다.

| 실험 | 문서 | 재현 SQL |
|---|---|---|
| Lost update 재현과 해결 (MySQL 8.4 InnoDB, REPEATABLE READ) | [lost-update.md](lost-update.md) | [sql/lost-update.sql](sql/lost-update.sql) |

## Lost update 실험 요약

검색어 카운트가 100이 되면 알림을 보내는 시나리오에서, 두 세션이 동시에 카운트를 올릴 때 결과를 비교했습니다.

| 방식 | 결과 | 근거 |
|---|---|---|
| 앱에서 계산한 값으로 UPDATE | 증가 2회 중 1회 소실 | 두 번째 UPDATE `Changed: 0` |
| 원자적 UPDATE (`count = count + 1`) | 정상 반영 | 최종 값 101 |
| `SELECT ... FOR UPDATE` | 정상 반영, 두 번째 조회가 대기 후 최신 값을 읽음 | `data_locks`의 `X,REC_NOT_GAP` GRANTED / WAITING |
| `SELECT ... FOR SHARE` | 데드락(1213), 희생 트랜잭션 전체 롤백 | `SHOW ENGINE INNODB STATUS`: 양쪽 S 보유, X 대기 |

## 재현 방법

재현 SQL은 한 번에 실행하는 스크립트가 아니라 절차서입니다. 터미널 두 개로 각각 접속한 뒤, 주석의 `[S1]`/`[S2]` 표시와 단계 번호 순서대로 실행합니다.
