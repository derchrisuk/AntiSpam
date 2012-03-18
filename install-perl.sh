#!/bin/sh

if [ ! -x `which cpan` ]; then
    echo "Sorry, you seem to be missing the cpan utility included with Perl."
    exit 1
fi

cpan \
    Cache::Memcached \
    Cache::Memcached::GetParserXS \
    Cache::Memory \
    Crypt::Rijndael \
    Date::Manip \
    DBD::mysql \
    Digest::SHA1 \
    Email::Valid \
    Encode::Detect \
    Encode::HanExtra \
    Encode::JIS2K \
    IO::AIO \
    LWP::UserAgent \
    LWPx::ParanoidAgent \
    Net::Akismet \
    Perlbal \
    Perlbal::XS::HTTPHeaders \
    Readonly \
    Readonly::XS \
    Sys::Load \
    Sys::MemInfo \
    URI::Find \
    URI::Find::Schemeless \
    YAML::Syck

cd ext-modules/CGI-Deurl-XS
perl Makefile.PL
make && make install
