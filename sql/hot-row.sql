-- hot row 재현 (MySQL 8.4, REPEATABLE-READ)
-- 사용법: 터미널 3개(F-1) / 2개(F-2)에서 각각 접속, 아래 [S1]/[S2]/[S3] 표시대로 단계 순서대로 실행

-- ===== 초기화 (실험 F-1전 S1에서) =====
CREATE DATABASE IF NOT EXISTS txlab; USE txlab;
DROP TABLE IF EXISTS keyword_stats;
CREATE TABLE keyword_stats (keyword VARCHAR(50) PRIMARY KEY, count INT NOT NULL) ENGINE=InnoDB;
INSERT INTO keyword_stats VALUES ('search', 99);
SELECT CONNECTION_ID();
-- S2: USE txlab;SELECT CONNECTION_ID();
-- S3: USE txlab;SELECT CONNECTION_ID();
-- CONNECTION_ID 각 15, 16, 17 (실험마다 다름)

-- ===== 실험 F-1: 한 행 쓰기 몰림 =====
-- 1 [S1]
BEGIN; UPDATE keyword_stats SET count = count + 1 WHERE keyword='search'; SELECT trx_id FROM information_schema.innodb_trx WHERE trx_mysql_thread_id = CONNECTION_ID();
-- 2 [S2] (50초 안에 2~6 단계 진행할 것)
BEGIN; UPDATE keyword_stats SET count = count + 1 WHERE keyword='search'; SELECT trx_id FROM information_schema.innodb_trx WHERE trx_mysql_thread_id = CONNECTION_ID();
-- 3 [S3]
SET SESSION innodb_lock_wait_timeout = 30;
BEGIN; UPDATE keyword_stats SET count = count + 1 WHERE keyword='search'; SELECT trx_id FROM information_schema.innodb_trx WHERE trx_mysql_thread_id = CONNECTION_ID();
-- 4 [S1]
SELECT engine_transaction_id, lock_type, lock_mode, lock_status, lock_data FROM performance_schema.data_locks;
SELECT * FROM performance_schema.data_lock_waits\G
-- 5 [S3] (30초 뒤 결과 확인 후)
SELECT count FROM keyword_stats WHERE keyword='search'; ROLLBACK;
-- 6 [S1]
COMMIT;
-- 7 [S2]
COMMIT;
-- 확인: 기대 101
SELECT * FROM keyword_stats;


-- ===== 초기화 (실험 F-2전 S1에서) =====
CREATE DATABASE IF NOT EXISTS txlab; USE txlab;
DROP TABLE IF EXISTS keyword_stats_shard;
CREATE TABLE keyword_stats_shard (
  keyword VARCHAR(50) NOT NULL, shard_id TINYINT NOT NULL, count INT NOT NULL,
  PRIMARY KEY (keyword, shard_id)) ENGINE=InnoDB;
INSERT INTO keyword_stats_shard VALUES ('search',0,99),('search',1,0),('search',2,0),('search',3,0);
-- S2: USE txlab;

-- ===== 실험 F-2: 샤드 분산 =====
-- 1 [S1]
BEGIN; UPDATE keyword_stats_shard SET count = count + 1 WHERE keyword='search' AND shard_id=0;
-- 2 [S2]
BEGIN; UPDATE keyword_stats_shard SET count = count + 1 WHERE keyword='search' AND shard_id=1;
-- 3 [S1]
SELECT engine_transaction_id, lock_type, lock_mode, lock_status, lock_data FROM performance_schema.data_locks;
SELECT * FROM performance_schema.data_lock_waits\G
-- 4 [S1]
COMMIT;
-- 5 [S2]
COMMIT;
-- 확인: 기대 101
SELECT SUM(count) FROM keyword_stats_shard WHERE keyword='search';

-- ===== MSSQL 실험 (MSSQL2022, REPEATABLE-READ) =====
-- ===== 초기화 (실험 G전 S1에서) =====
CREATE DATABASE txlab;
GO
USE txlab;
DROP TABLE IF EXISTS keyword_stats;
CREATE TABLE keyword_stats (keyword VARCHAR(50) PRIMARY KEY, count INT NOT NULL);
INSERT INTO keyword_stats VALUES ('search', 99);
GO
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT @@SPID;
GO
-- ===== 초기화 (실험 G전 S2에서) =====
USE txlab;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT @@SPID;
GO
-- SPID 각각 73, 74 (실험마다 다름)

-- ===== 실험 G-1 : 앱에서 계산한 값으로 UPDATE =====
-- 1 [S1]
BEGIN TRAN; SELECT count FROM keyword_stats WHERE keyword='search';
