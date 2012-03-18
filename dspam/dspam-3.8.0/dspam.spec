Summary: DSPAM configured with mysql support
Name: dspam
Version: 3.8.0
Release: serotype_1.6.17.1
License: GPL
Source:%{name}-%{version}.tar.gz
Group: Networking/Mail
BuildRoot:/tmp/%{name}-root

BuildRequires: MySQL-devel-community >= 5.0.51
BuildRequires: zlib-devel
Requires: MySQL-client-community >= 5.0.51
Requires: MySQL-shared-community >= 5.0.51
Requires: libmemcached >= 0.23

%description

DSPAM is a scalable and open-source content-based spam filter designed for
multi-user enterprise systems. On a properly configured system, many users
experience results between 99.5% - 99.95%, or one error for every 200 to 2000
messages. DSPAM supports many different MTAs and can also be deployed as a
stand-alone SMTP appliance. For developers, the DSPAM core engine (libdspam)
can be easily incorporated directly into applications for drop-in filtering
(GPL applies; commercial licenses are also available). 

This RPM configures dspam for the Serotype application.  It includes support
for libmemcache in the MySQL driver.

%prep

%setup -q

%build
sh autogen.sh
env CFLAGS='-O3 -march=nocona' \
sh configure \
    --prefix=/usr \
    --libdir=/usr/lib64 \
    --sysconfdir=/etc/serotype \
    --with-dspam-home=/var/dspam \
    --with-dspam-mode=755 \
    --disable-preferences-extension \
    --enable-long-usernames \
    --enable-large-scale \
    --enable-virtual-users \
    --enable-shared \
    --disable-static \
    --disable-trusted-user-security \
    --enable-daemon \
    --with-storage-driver=mysql_drv \
    --with-mysql-includes=/usr/include/mysql \
    --with-mysql-libraries=/usr/lib64/mysql \
    --enable-memcache

make

%install
make DESTDIR=${RPM_BUILD_ROOT} install
mkdir -p ${RPM_BUILD_ROOT}/var/run/spam
mkdir -p ${RPM_BUILD_ROOT}/var/dspam

%clean

%files
%defattr(-,root,root)
%doc /usr/man/*/*
%{_bindir}/dspam
%{_bindir}/dspamc
%{_bindir}/dspam_*
/usr/lib64/libdspam*
/usr/lib64/pkgconfig/dspam.pc
%{_includedir}/dspam/*
%attr(755,comet,comet) /var/run/spam/
%attr(755,comet,comet) /var/dspam/
%attr(600,comet,comet) %config(noreplace) /etc/serotype/dspam.conf
%attr(640,comet,comet) %config(noreplace) /var/dspam/group

%changelog
* Wed Apr  11 2007  Adam Thomason
- Initial version
