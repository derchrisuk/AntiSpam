#!/bin/sh
set -x

export PERL5LIB=./lib:./ext-lib

perl tools/yuidd -d
memcached -d -u nobody
gearmand -d -u root
dspam --daemon &

export GEARMAND_SERVER=127.0.0.1:4730
perlbal -c conf/perlbal.conf
