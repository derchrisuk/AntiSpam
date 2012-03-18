CREATE DATABASE IF NOT EXISTS serotype_log;
GRANT ALL PRIVILEGES ON serotype_log.* to 'serotype'@'localhost' IDENTIFIED BY '' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON serotype_log.* to 'serotype'@'%'         IDENTIFIED BY '' WITH GRANT OPTION;

USE serotype_log;

DROP TABLE IF EXISTS action_dim;
CREATE TABLE action_dim (
    action_dim_id   SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    action          VARCHAR(32) NOT NULL,
    UNIQUE INDEX    (action)
) ENGINE=InnoDB;
INSERT INTO action_dim (action) VALUES
    ('verify-key'),
    ('comment-check'),
    ('submit-ham'),
    ('submit-spam'),
    ('notify');

DROP TABLE IF EXISTS api_key_dim;
CREATE TABLE api_key_dim (
    api_key_dim_id  INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    api_key         VARCHAR(64) NOT NULL UNIQUE,
    UNIQUE INDEX    (api_key)
) ENGINE=InnoDB;

DROP TABLE IF EXISTS ip_dim;
CREATE TABLE ip_dim (
    ip_dim_id       INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    ip              CHAR(15) NOT NULL UNIQUE,
    UNIQUE INDEX    (ip)
) ENGINE=InnoDB;

-- identifying string for the handling worker
DROP TABLE IF EXISTS worker_dim;
CREATE TABLE worker_dim (
    worker_dim_id   INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    worker          VARCHAR(64) NOT NULL UNIQUE,
    UNIQUE INDEX    (worker)
) ENGINE=InnoDB;

-- comment/trackback/etc
DROP TABLE IF EXISTS type_dim;
CREATE TABLE type_dim (
    type_dim_id     INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    type            VARCHAR(64) NULL UNIQUE,
    UNIQUE INDEX    (type)
) ENGINE=InnoDB;
INSERT INTO type_dim (type) VALUES
    ('comment'),
    ('trackback'),
    ('pingback');

DROP TABLE IF EXISTS date_dim;
CREATE TABLE date_dim (
    date_id         SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    the_day         DATE,
    day_of_week     CHAR(2),
    week_number     INT,
    day_of_month    TINYINT UNSIGNED,
    month_of_year   TINYINT UNSIGNED,
    the_year        INT UNSIGNED,
    start_time      INT UNSIGNED,
    end_time        INT UNSIGNED,

    INDEX           (the_day),
    INDEX           (start_time, end_time)
) ENGINE=MyISAM; -- read-only table

DROP TABLE IF EXISTS reviewers;
CREATE TABLE reviewers (
    reviewer_id     INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    reviewer        VARCHAR(255)
) ENGINE=InnoDB;

DROP TABLE IF EXISTS reviews;
CREATE TABLE reviews (
    review_id       INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,

    request_log_id  BIGINT UNSIGNED NOT NULL,   -- yuid id
    reviewer_id     INT UNSIGNED NOT NULL,

    rating          TINYINT UNSIGNED,           -- same as in request_log
    confidence      FLOAT,                      -- [0.0-1.0]

    authoritative   BOOL,                       -- eg human reviewed

    start_time      BIGINT UNSIGNED NOT NULL,   -- ms since epoch
    end_time        BIGINT UNSIGNED NOT NULL,   -- ms since epoch
    date_id         SMALLINT UNSIGNED,

    INDEX           (request_log_id),
    INDEX           (reviewer_id),
    INDEX           (rating),
    INDEX           (date_id)
) ENGINE=InnoDB;

-- mapping from request id to date
DROP TABLE IF EXISTS id_date_map;
CREATE TABLE id_date_map (
    request_log_id  BIGINT UNSIGNED NOT NULL PRIMARY KEY,
    date_id         SMALLINT UNSIGNED
) ENGINE=InnoDB;
