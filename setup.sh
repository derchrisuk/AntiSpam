#!/bin/sh

MYSQL=mysql

cat sql/client/init.sql \
    sql/log/init.sql \
    sql/dspam/init.sql \
    | $MYSQL -u root -p

echo "LOAD DATA LOCAL INFILE 'sql/log/date_dim.csv' INTO TABLE date_dim" | $MYSQL -u serotype serotype_log
