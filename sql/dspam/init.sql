create database if not exists dspam;
grant all privileges on dspam.* TO 'dspam'@'localhost' identified by 'dspam' with grant option;
grant all privileges on dspam.* TO 'dspam'@'%'         identified by 'dspam' with grant option;

use dspam;

create table dspam_token_data (
  uid int unsigned not null,
  token char(20) not null,
  spam_hits int not null,
  innocent_hits int not null,
  last_hit date not null
) type=InnoDB;

create unique index id_token_data_01 on dspam_token_data(uid,token);

create table dspam_signature_data (
  uid int unsigned not null,
  signature char(32) not null,
  data blob not null,
  length int not null,
  created_on date not null
) type=InnoDB;

create unique index id_signature_data_01 on dspam_signature_data(uid,signature);
create index id_signature_data_02 on dspam_signature_data(created_on);

create table dspam_stats (
  uid int unsigned primary key,
  spam_learned int not null,
  innocent_learned int not null,
  spam_misclassified int not null,
  innocent_misclassified int not null,
  spam_corpusfed int not null,
  innocent_corpusfed int not null,
  spam_classified int not null,
  innocent_classified int not null
) type=InnoDB;

create table dspam_preferences (
  uid int unsigned not null,
  preference varchar(32) not null,
  value varchar(64) not null
) type=InnoDB;

create unique index id_preferences_01 on dspam_preferences(uid, preference);

create table dspam_virtual_uids (
  uid int unsigned primary key AUTO_INCREMENT,
  username varchar(128)
) type=InnoDB;

create unique index id_virtual_uids_01 on dspam_virtual_uids(username);
