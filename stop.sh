#!/bin/sh
set -x
ps auxwww | egrep 'yuidd|memcached|gearmand|dspam' | grep -v egrep | awk '{print $2}' | xargs kill
