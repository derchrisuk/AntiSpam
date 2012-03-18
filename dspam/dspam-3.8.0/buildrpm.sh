#!/bin/sh

# this script requires automake, autoconf, libtool, and pkgconfig to be installed

CWD=`pwd`
CURDIRNAME=`basename $CWD`
PLATFORM=`uname -p`

set -x

rm -rf rpm
mkdir rpm
mkdir rpm/RPMS rpm/SPECS rpm/SOURCES rpm/BUILD
(cd ..; tar --exclude=.svn -zcf $CURDIRNAME/rpm/SOURCES/$CURDIRNAME.tar.gz $CURDIRNAME)
rpmbuild  --define "_topdir $CWD/rpm" -bb dspam.spec
#rpmbuild  --define "_topdir $CWD/rpm" --define "_rpmfilename $CURDIRNAME.$PLATFORM.rpm" -bb dspam.spec
