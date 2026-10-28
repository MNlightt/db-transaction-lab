-- w02 lost update 재현 (MySQL 8.4, REPEATABLE-READ)
-- 사용법: 터미널 2개에서 각각 접속, 아래 [S1]/[S2] 표시대로 단계 순서대로 실행

-- ===== 초기화 (각 실험 전, S1에서) =====
CREATE DATABASE IF NOT EXISTS txlab; USE txlab;
DROP TABLE IF EXISTS keyword_stats;
CREATE TABLE keyword_stats (keyword VARCHAR(50) PRIMARY KEY, count INT NOT NULL) ENGINE=InnoDB;
INSERT INTO keyword_stats VALUES ('search', 99);
-- S2: USE txlab;

-- ===== 실험 A: 앱 계산값 UPDATE (lost update 재현) =====
-- 1 [S1]
BEGIN; SELECT count FROM keyword_stats WHERE keyword='search';
-- 2 [S2]
BEGIN; SELECT count FROM keyword_stats WHERE keyword='search';
-- 3 [S1]
UPDATE keyword_stats SET count = 100 WHERE keyword='search';
-- 4 [S2] 대기 발생
UPDATE keyword_stats SET count = 100 WHERE keyword='search';
-- 5 [S1]
COMMIT;
-- 5 [S2] 대기 풀린 뒤
COMMIT;
-- 확인: 기대 100 (Changed: 0)
SELECT count FROM keyword_stats WHERE keyword='search';

-- ===== 실험 B: 원자적 UPDATE =====
-- 1 [S1]
BEGIN; SELECT count FROM keyword_stats WHERE keyword='search';
-- 2 [S2]
BEGIN; SELECT count FROM keyword_stats WHERE keyword='search';
-- 3 [S1]
UPDATE keyword_stats SET count = count + 1 WHERE keyword='search';
-- 4 [S2] 대기 발생
UPDATE keyword_stats SET count = count + 1 WHERE keyword='search';
-- 5 [S1]
COMMIT;
-- 6 [S2] 기대 101 (자기 트랜잭션 내에서 바꾼 내용)
SELECT count FROM keyword_stats WHERE keyword='search';
-- 7 [S2] 대기 풀린 뒤
COMMIT;
-- 확인: 기대 101
SELECT count FROM keyword_stats WHERE keyword='search';

-- ===== 실험 C: SELECT ... FOR UPDATE =====
-- 1 [S1]
BEGIN; SELECT count FROM keyword_stats WHERE keyword='search' FOR UPDATE;
-- 2 [S2] 대기 발생 (50초 안에 3~5 진행할 것)
BEGIN; SELECT count FROM keyword_stats WHERE keyword='search' FOR UPDATE;
-- 3 [S1] 락 관찰
SELECT engine_transaction_id, lock_type, lock_mode, lock_status, lock_data
  FROM performance_schema.data_locks;
SELECT * FROM performance_schema.data_lock_waits\G
-- 4 [S1]
UPDATE keyword_stats SET count = count + 1 WHERE keyword='search';
-- 5 [S1]
COMMIT;
-- 6 [S2] SELECT가 100 반환한 뒤
UPDATE keyword_stats SET count = count + 1 WHERE keyword='search';
COMMIT;
-- 확인: 기대 101
SELECT count FROM keyword_stats WHERE keyword='search';

-- ===== 실험 D: SELECT ... FOR SHARE =====
-- 1 [S1]
BEGIN; SELECT count FROM keyword_stats WHERE keyword='search' FOR SHARE;
-- 2 [S2]
BEGIN; SELECT count FROM keyword_stats WHERE keyword='search' FOR SHARE;
-- 3 [S1] 대기 발생
UPDATE keyword_stats SET count = count + 1 WHERE keyword='search';
-- 4 [S2] 데드락 발생,트랜잭션 롤백
UPDATE keyword_stats SET count = count + 1 WHERE keyword='search';
-- 5 [S1] 대기 풀린 뒤
COMMIT;
-- 6 [S2] 기대 100 트랜잭션 롤백 관찰(S1의 업데이트만 이루어졌으니 101이 아닌 100)
SELECT count FROM keyword_stats WHERE keyword='search';
-- 7 [S1] 데드락 관찰 (LATEST DETECTED DEADLOCK 파트)
SHOW ENGINE INNODB STATUS\G
-- 확인: 기대 100
SELECT count FROM keyword_stats WHERE keyword='search';