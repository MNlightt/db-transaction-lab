# 격리수준과 이상현상
근거 표기: T·M은 아래 출처 약어, A~H는 이 저장소의 실험

| 격리수준 | Dirty read | Non-repeatable read | Phantom | Lost update (읽고 계산해서 쓰기) |
|---|---|---|---|---|
| READ UNCOMMITTED | 발생(T2) | 발생(T2) | 발생(T2) | 발생(T2) |
| READ COMMITTED | 방지(T2) | 발생(T2)| 발생(T2) | 발생(T2) |
| REPEATABLE READ (InnoDB) | 방지(T2) | 방지(T1) | 스냅샷 읽기: 방지(T1), 잠금 읽기: 방지(H-2)(섞어 읽는 경우 확인 불가) | 발생(A) |
| REPEATABLE READ (SQL Server) | 방지(M1)| 방지(M1) | 발생(M1) | 방지(G-1, 한쪽이 1205로 중단되므로 재시도 필요) |
| SERIALIZABLE | 방지(T1) | 방지(T1) | 방지(T1) | 방지(T1, “autocommit이 꺼진 트랜잭션에서” 일반 SELECT를 FOR SHARE로 변경. 실험 D와 유사[추론]) |


- 각 이상현상 한 줄 정의:
  커밋되지 않은 트랜잭션 값을 보는 것
  같은 트랜잭션에서 이미 읽은 행을 다시 읽었을 때 값이 다른 것
  조건을 다시 평가했는데 조건에 맞는 행 집합이 달라진 것
  두 트랜잭션이 같은 값을 읽고 각자 계산해 쓰면서, 한쪽 갱신이 에러 없이 덮어써지는 것

- InnoDB RR이 표준 정의와 다른 점: 표준 RR은 phantom을 허용하지만, InnoDB RR은 스냅샷과 next-key로 대부분 막습니다.
  일반 SELECT가 락 없는 스냅샷 읽기이기 때문에 lost update는 막지 않습니다(A). 같은 RR에서 SQL Server는 막습니다(G-1)
  읽기가 두 종류입니다. 일반 SELECT는 스냅샷, FOR UPDATE·UPDATE는 최신 커밋을 읽습니다(B 본 결과, C)

- 실험을 통해 배운 점: 같은 RR이라 하더라도 MySQL에서와 SQL SERVER에서 Lost update 결과가 달랐습니다.
  MySQL에서는 스냅샷 읽기로 인해 Lost update가 발생하는 반면 SQL SERVER는 S락을 유지함으로써 이를 방지했습니다.
  따라서 InnoDB에서는 Lost update가 일어나지 않도록 원자적 UPDATE(B)를 쓰거나, 읽고 계산하는 흐름이 필요하면 SELECT ... FOR UPDATE(C)로 방지하는 방식을 택해야 할 것입니다. 
  또한 앱 관점에서는 1213, 1205 등 에러에 대한 재시도 로직을 잘 설계해야 합니다.
  

출처 약어: T1 = MySQL 8.4 Reference Manual (InnoDB 트랜잭션 모델과 락), T2 = Hermitage (Martin Kleppmann, 격리수준별 이상현상 실측), M1 = Microsoft Learn Transaction Locking and Row Versioning Guide. 실험 기호 A~H는 이 저장소의 각 실험 문서를 가리킵니다(A~D: lost-update.md, E: deadlock.md, F: hot-row.md, G: mssql-lost-update.md, H: lock-range.md).
