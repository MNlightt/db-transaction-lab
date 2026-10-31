-- 접근 순서 데드락 재현 (MySQL 8.4, REPEATABLE-READ)
-- 사용법: 터미널 2개에서 각각 접속, 아래 [S1]/[S2] 표시대로 단계 순서대로 실행

-- ===== 초기화 (각 실험 E-1,E-2 전, S1에서) =====
CREATE DATABASE IF NOT EXISTS txlab; USE txlab;
DROP TABLE IF EXISTS keyword_stats;
CREATE TABLE keyword_stats (keyword VARCHAR(50) PRIMARY KEY, count INT NOT NULL) ENGINE=InnoDB;
INSERT INTO keyword_stats VALUES ('news', 50), ('search', 99);
-- S2: USE txlab;

-- ===== 실험 E-1: 역순 업데이트 데드락 =====
-- 1 [S1]
BEGIN; UPDATE keyword_stats SET count = count + 1 WHERE keyword='search';
-- 2 [S2]
BEGIN; UPDATE keyword_stats SET count = count + 1 WHERE keyword='news';
-- 3 [S1] 대기 발생
UPDATE keyword_stats SET count = count + 1 WHERE keyword='news';
-- 4 [S2] 데드락 발생, 트랜잭션 롤백
UPDATE keyword_stats SET count = count + 1 WHERE keyword='search';
-- 5 [S1]
COMMIT;
-- 6 [S2] 기대 news: 51, search: 100 트랜잭션 롤백 관찰
SELECT * FROM keyword_stats;
-- 7 [S1] 데드락 관찰 (LATEST DETECTED DEADLOCK 파트)
SHOW ENGINE INNODB STATUS\G
-- 확인: 기대 news: 51, search: 100
SELECT * FROM keyword_stats;

-- ===== 실험 E-2: 정렬 업데이트 단순 대기 =====
-- 1 [S1]
BEGIN; UPDATE keyword_stats SET count = count + 1 WHERE keyword='news';
-- 2 [S2] 대기 발생 (50초 안에 3~5 진행할 것)
BEGIN; UPDATE keyword_stats SET count = count + 1 WHERE keyword='news';
-- 3 [S1] 락 관찰
SELECT engine_transaction_id, lock_type, lock_mode, lock_status, lock_data
  FROM performance_schema.data_locks;
SELECT * FROM performance_schema.data_lock_waits\G
-- 4 [S1] 
UPDATE keyword_stats SET count = count + 1 WHERE keyword='search';
-- 5 [S1]
COMMIT;
-- 6 [S2] 대기 풀린 뒤
UPDATE keyword_stats SET count = count + 1 WHERE keyword='search';
COMMIT;
-- 확인: 기대 news: 52, search: 101
SELECT * FROM keyword_stats;

