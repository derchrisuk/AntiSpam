CREATE DATABASE IF NOT EXISTS serotype;
GRANT ALL PRIVILEGES ON serotype.* to 'serotype'@'localhost' IDENTIFIED BY '' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON serotype.* to 'serotype'@'%'         IDENTIFIED BY '' WITH GRANT OPTION;

USE serotype;

-- individual users with an API key
DROP TABLE IF EXISTS client_dim;
CREATE TABLE client_dim (
    client_dim_id   INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,

    -- visible identifier
    api_key         VARCHAR(254)  NOT NULL,  -- "secret" key used by user to identify+authenticate to us (req'd by akismet api)

    -- backend identifier
    backend_id      CHAR(32)     NOT NULL,  -- unique token used to identify user to backend

    special_class_id INT UNSIGNED    NULL,  -- special class, if any

    -- capabilities
    enabled         BOOLEAN DEFAULT FALSE,  -- if false, client is disabled.
    may_query       BOOLEAN DEFAULT FALSE,  -- client may execute "comment-check"
    may_train_spam  BOOLEAN DEFAULT FALSE,  -- client may execute "submit-spam"
    may_train_ham   BOOLEAN DEFAULT FALSE,  -- client may execute "submit-ham"
    may_follow_link BOOLEAN DEFAULT FALSE,  -- client may request that service fetch pages linked in content (placeholder)
    send_confidence BOOLEAN DEFAULT FALSE,  -- client may request that service return X-Antispam-Confidence header

    -- statistics
    num_queries     INT UNSIGNED NOT NULL,  -- number of "comment-check" requests executed
    num_spam        INT UNSIGNED NOT NULL,  -- number of "submit-spam" requests executed
    num_ham         INT UNSIGNED NOT NULL,  -- number of "submit-ham" requests executed
    num_verified    INT UNSIGNED NOT NULL,  -- number of "verify-key" requests executed

    -- reputation
    trust           FLOAT,                  -- app-defined trust metric for user
    trust_mutable   BOOLEAN DEFAULT TRUE,   -- if true, serotype will update trust

    -- track when we heard from this user
    first_contact   DATETIME,               -- timestamp when user record was created
    last_contact    DATETIME,               -- timestamp when user record was last updated
    last_ip         CHAR(15),               -- IP address of last contact

    UNIQUE INDEX    (api_key),
    INDEX           (special_class_id)
) engine=InnoDB;

-- store a bit of extra info for specific clients
DROP TABLE IF EXISTS client_info;
CREATE TABLE client_info (
    client_dim_id   INT UNSIGNED NOT NULL PRIMARY KEY,

    -- free text
    info            VARCHAR(512) NOT NULL,

    INDEX           (info)
) engine=InnoDB;

-- urls appearing in object text
DROP TABLE IF EXISTS url_dim;
CREATE TABLE url_dim (
    url_dim_id      INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,

    signature       CHAR(22) NOT NULL,

    UNIQUE INDEX    (signature)
) engine=InnoDB;

-- urls rated by users
DROP TABLE IF EXISTS url_fact;
CREATE TABLE url_fact (
    url_fact_id     INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,

    -- the url this applies to
    url_dim_id      INT UNSIGNED NOT NULL,

    -- who trained it?
    client_dim_id   INT UNSIGNED NOT NULL,

    -- what did the client call it?
    disposition     ENUM('spam', 'ham', 'abstain') NOT NULL DEFAULT 'abstain',

    -- did we train on this message?
    accepted        BOOLEAN NOT NULL DEFAULT FALSE,

    -- when did the rating come in?
    date            DATETIME,
    date_id         SMALLINT UNSIGNED,

    INDEX           (url_dim_id),
    INDEX           (client_dim_id),
    INDEX           (disposition),
    INDEX           (date_id)
) engine=InnoDB;

-- classes whose keys are handled specially in code
DROP TABLE IF EXISTS special_class;
CREATE TABLE special_class (
    special_class_id
                    INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name            VARCHAR(32)  NOT NULL,
    UNIQUE INDEX    (name)
) engine=InnoDB;

-- audit history of changes to trust level
DROP TABLE IF EXISTS trust_audit_history;
CREATE TABLE trust_audit_history (
    trust_audit_history_id
                    INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    date            DATETIME,       -- timestamp
    user_id         INT UNSIGNED,   -- client_dim_id of user donating trust
    user_trust      FLOAT,          -- donating user's trust value
    peer_id         INT UNSIGNED,   -- client_dim_id of user receiving trust
    peer_trust      FLOAT,          -- receiving user's old trust value
    ratio           FLOAT           -- ratio of new trust value to old
) engine=InnoDB;

DROP TABLE IF EXISTS domain_whitelist;
CREATE TABLE domain_whitelist (
    domain_whitelist_id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    domain          VARCHAR(255),
    added_on        DATETIME,
    date_id         SMALLINT UNSIGNED,
    added_by        VARCHAR(255),
    reason          VARCHAR(255),
    INDEX           (domain),
    INDEX           (date_id)
) engine=InnoDB;

DROP TABLE IF EXISTS domain_blacklist;
CREATE TABLE domain_blacklist (
    domain_blacklist_id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    domain          VARCHAR(255),
    added_on        DATETIME,
    date_id         SMALLINT UNSIGNED,
    added_by        VARCHAR(255),
    reason          VARCHAR(255),
    INDEX           (domain),
    INDEX           (date_id)
) engine=InnoDB;

DROP TABLE IF EXISTS date_dim;
CREATE TABLE date_dim (
    date_id         SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    the_day         DATE,
    day_of_week     CHAR(2),
    week_number     INT,
    day_of_month    TINYINT,
    month_of_year   TINYINT,
    the_year        INT,
    start_time      INT,
    end_time        INT,

    INDEX           (the_day),
    INDEX           (start_time, end_time)
) engine=MyISAM; -- read-only table
