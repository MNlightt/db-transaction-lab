-- w02 인덱스 유무와 락 범위 재실험 (1주차 실습 4-1/4-2, MySQL 8.4, REPEATABLE-READ)
-- 사용법: 터미널 2개에서 각각 접속, 아래 [S1]/[S2] 표시대로 단계 순서대로 실행
-- 1주차 초기화 SQL은 기록이 없어 1주차 data_locks 출력(id 1~5, 'search'=1, 다음 키 'stock'=5) 기준으로 재구성

-- ===== 초기화 (S1에서, H-1 전, H-2 전) =====
CREATE DATABASE IF NOT EXISTS txlab; USE txlab;
DROP TABLE IF EXISTS keyword_stats_w01;
CREATE TABLE keyword_stats_w01 (
  id INT AUTO_INCREMENT PRIMARY KEY,
  keyword VARCHAR(50) NOT NULL,
  count INT NOT NULL DEFAULT 0) ENGINE=InnoDB;
INSERT INTO keyword_stats_w01 (id, keyword) VALUES
  (1,'search'),(2,'news'),(3,'weather'),(4,'movie'),(5,'stock');
-- 키워드 정렬 순서: movie < news < search < stock < weather

-- ===== 세션 준비 =====
-- [S1]
SELECT CONNECTION_ID();
-- [S2] 막히는 문장을 5초 만에 확인하려고 타임아웃을 줄임
USE txlab; SELECT CONNECTION_ID();
SET SESSION innodb_lock_wait_timeout = 5;
-- CONNECTION_ID: S1 = __, S2 = __

-- ===== 실험 H-1: 인덱스 없음 =====
-- 1 [S1]
BEGIN; UPDATE keyword_stats_w01 SET count = count + 1 WHERE keyword='search';
SELECT trx_id FROM information_schema.innodb_trx WHERE trx_mysql_thread_id = CONNECTION_ID();
-- 2 [S2] 기대: 1205 (PRIMARY id 3 레코드가 잠김)
UPDATE keyword_stats_w01 SET count = count + 1 WHERE keyword='weather';
-- 3 [S2] 기대: 1205 (id 6 자리 = supremum 앞 간격이 잠김)
INSERT INTO keyword_stats_w01 (keyword) VALUES ('apple');
-- 4 [S1] 기대: PRIMARY X 1~5 + supremum pseudo-record
SELECT index_name, lock_type, lock_mode, lock_status, lock_data FROM performance_schema.data_locks;
-- 5 [S1]
ROLLBACK;

-- ===== 초기화 재실행 (S1에서, H-2 전): 위 초기화 블록과 동일 =====
-- ===== 실험 H-2: 인덱스 추가 후 반복 =====
-- 0 [S1]
CREATE INDEX idx_keyword ON keyword_stats_w01(keyword);
-- 1 [S1]
BEGIN; UPDATE keyword_stats_w01 SET count = count + 1 WHERE keyword='search';
-- 2 [S1] 기대: idx_keyword X 'search',1 + idx_keyword X,GAP 'stock',5 + PRIMARY X,REC_NOT_GAP 1
SELECT index_name, lock_type, lock_mode, lock_status, lock_data FROM performance_schema.data_locks;
-- 3 [S2] 기대: 즉시 성공 (다른 레코드)
UPDATE keyword_stats_w01 SET count = count + 1 WHERE keyword='weather';
-- 4 [S2] 기대: 즉시 성공 (movie 앞 간격, 잠긴 범위 밖)
INSERT INTO keyword_stats_w01 (keyword) VALUES ('apple');
-- 5 [S2] 기대: 1205 ((news, search] 간격, 'search'의 next-key X)
INSERT INTO keyword_stats_w01 (keyword) VALUES ('rain');
-- 6 [S2] 기대: 1205 ((search, stock) 간격, 'stock'의 X,GAP)
INSERT INTO keyword_stats_w01 (keyword) VALUES ('sports');
-- 7 [S2] 기대: 즉시 성공 (weather 뒤 간격, 잠긴 범위 밖)
INSERT INTO keyword_stats_w01 (keyword) VALUES ('zebra');
-- 8 [S1]
ROLLBACK;
-- 확인: S2의 autocommit 문장(weather +1, apple, zebra)은 반영되어 있음. H-2를 다시 하려면 초기화부터.
SELECT * FROM keyword_stats_w01 ORDER BY keyword;
