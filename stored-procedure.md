# T-SQL Stored Procedure — 날짜별 검색어 순위 집계

## 개요

- DB: SQL Server 2022 (Docker, `lab` DB)
- 파일: [`sql/usp_build_keyword_rank.sql`](sql/usp_build_keyword_rank.sql) (DDL, 샘플 데이터, SP, 검증 쿼리 포함)
- 동작: `@target_date`의 `search_log`를 키워드별로 집계해 상위 `@top_n`개를 `keyword_rank`에 저장. 같은 날짜로 다시 실행하면 DELETE 후 INSERT로 덮어씀
- 트랜잭션 처리: `BEGIN TRAN` + `TRY/CATCH`, 에러 시 `IF @@TRANCOUNT > 0 ROLLBACK` 후 `THROW`로 호출자에게 에러 전달

## 검증

| 검증 | 실행 | 기대 | 결과 |
|---|---|---|---|
| 1. 정상 실행 | `@top_n = 3` | 1 search 3 / 2 news 2 / 3 weather 2, 다른 날짜 제외 | 일치: search 3 / news 2 / weather 2 |
| 2. 같은 날짜 재실행 | `@top_n = 3` 다시 | 중복 없이 같은 3행 | 일치: search 3 / news 2 / weather 2 |
| 3. INSERT 단계 에러 | `@top_n = -1` | 에러 후 DELETE까지 롤백, 3행 유지 | 일치: search 3 / news 2 / weather 2 |

근거 출력:

```

--1
rank_date        rank_no     keyword                                            cnt        
---------------- ----------- -------------------------------------------------- -----------
      2026-10-27           1 search                                                       3
      2026-10-27           2 news                                                         2
      2026-10-27           3 weather                                                      2

--2
rank_date        rank_no     keyword                                            cnt        
---------------- ----------- -------------------------------------------------- -----------
      2026-10-27           1 search                                                       3
      2026-10-27           2 news                                                         2
      2026-10-27           3 weather                                                      2

--3
에러 발생 후 트랜잭션 롤백 DELETE 취소
Msg 127, Level 15, State 1, Server 3810dde38e63, Procedure usp_build_keyword_rank, Line 12
A TOP N or FETCH rowcount value may not be negative.
rank_date        rank_no     keyword                                            cnt        
---------------- ----------- -------------------------------------------------- -----------
      2026-10-27           1 search                                                       3
      2026-10-27           2 news                                                         2
      2026-10-27           3 weather                                                      2
```

## 수정 이력

- 10/27: `TOP`은 쿼리 끝 `ORDER BY` 기준으로 자른다는 점을 몰라 `ORDER BY keyword`로 작성 → `ORDER BY cnt DESC`로 수정
- 11/01: 동점이 있으면 `ROW_NUMBER()`와 `TOP ... ORDER BY cnt DESC`가 동점을 각자 임의로 정렬해 rank_no가 1, 2, 4처럼 뽑힐 수 있음(editor 지적) → 두 곳 모두 `COUNT(*) DESC, keyword` 기준으로 통일하고 `ORDER BY rank_no`로 자름

## 이번 주 주제(트랜잭션·락)와의 연결

- 원자성: DELETE와 INSERT를 한 트랜잭션으로 묶어, INSERT가 실패해도 그날 순위가 비어 버리지 않음(검증 3)
- 동시 실행 (실험 안 함, 추론): 기본 READ COMMITTED에서 같은 날짜로 두 세션이 동시에 실행하면, 둘 다 지울 행이 없는 상태로 DELETE를 지나 각자 INSERT해 순위가 중복될 수 있음. 대응은 `PRIMARY KEY (rank_date, rank_no)`(두 번째 실행이 중복 키 에러) 또는 `sp_getapplock`으로 직렬화
- 실무 연결: 랭킹을 요청 시점에 재집계하던 구조에서 동시 요청 대비가 없었던 문제와 같은 모양
