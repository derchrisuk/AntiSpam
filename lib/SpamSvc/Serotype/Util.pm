package SpamSvc::Serotype::Util;

use strict;
use warnings;

use Carp;
use Date::Manip;
use Crypt::Rijndael;
use MIME::Base64;
use POSIX 'strftime';
use URI::Find;
use URI::Find::Schemeless;

use base 'Exporter';

our @EXPORT_OK = qw/
    count_uris uri_counts most_frequent_uri
    count_uris_schemeless uri_counts_schemeless most_frequent_uri_schemeless
    encrypt_to_base64 decrypt_from_base64
    round_to_nearest_log
    str2midnight str2time time2date
    fuzzy_interval
    printable_interval commify
    mtime
/;

# returns the total number of URIs in a block of text
my $uri_counter;
sub count_uris {
    my $thing = shift;

    $thing = \"$thing" unless ref $thing eq 'SCALAR';

    $uri_counter ||= URI::Find->new(sub { $_[1] });

    return $uri_counter->find($thing) || 0;
}

my $uri_counter_schemeless;
sub count_uris_schemeless {
    my $thing = shift;

    $thing = \"$thing" unless ref $thing eq 'SCALAR';

    $uri_counter_schemeless ||= URI::Find::Schemeless->new(sub { $_[1] });

    return $uri_counter_schemeless->find($thing) || 0;
}

# returns a hashref containing each URI and its frequency
sub uri_counts {
    my $thing = shift;

    $thing = \"$thing" unless ref $thing eq 'SCALAR';

    my %count;
    my $uri_counter = URI::Find->new(sub {
        $count{$_[1]}++;
        $_[1];
    });

    $uri_counter->find($thing);
    return \%count;
}

sub uri_counts_schemeless {
    my $thing = shift;

    $thing = \"$thing" unless ref $thing eq 'SCALAR';

    my %count;
    my $uri_counter = URI::Find::Schemeless->new(sub {
        $count{$_[1]}++;
        $_[1];
    });

    $uri_counter->find($thing);
    return \%count;
}

# returns the most common URI in a block of text. if called in list context, also returns the count for that URI
sub most_frequent_uri {
    my $counts = uri_counts(shift);
    if (%$counts) {
        my $uri = (sort {$counts->{$b} <=> $counts->{$a}} keys %$counts)[0];
        return wantarray ? ($uri => $counts->{$uri}) : $uri;
    }
    else {
        return undef;
    }
}

sub most_frequent_uri_schemeless {
    my $counts = uri_counts_schemeless(shift);
    if (%$counts) {
        my $uri = (sort {$counts->{$b} <=> $counts->{$a}} keys %$counts)[0];
        return wantarray ? ($uri => $counts->{$uri}) : $uri;
    }
    else {
        return undef;
    }
}

sub cipher {
    my $key = shift;
    return Crypt::Rijndael->new($key, Crypt::Rijndael::MODE_CBC);
}

sub _pad {
    my ($text_ref, $bs) = @_;
    return unless length($$text_ref) % $bs;
    $$text_ref .= "\0" x ($bs - length($$text_ref) % $bs);
}

# encrypts an arbitrary string into base64. key must be 32 bytes long (hopefully binary).
sub encrypt_to_base64 {
    my $key                 = shift;
    my $plain_text          = shift;

    my $cipher              = cipher($key);

    _pad(\$plain_text, $cipher->blocksize);

    my $cipher_text         = $cipher->encrypt($plain_text);
    my $encoded_cipher_text = encode_base64($cipher_text, '');
    return $encoded_cipher_text;
}

# undoes encrypt_to_base64
sub decrypt_from_base64 {
    my $key                 = shift;
    my $encoded_cipher_text = shift;

    my $cipher              = cipher($key);

    _pad(\$encoded_cipher_text, $cipher->blocksize);

    my $cipher_text         = decode_base64($encoded_cipher_text);
    my $padded_text         = $cipher->decrypt($cipher_text) . '';
    my $plain_text          = $padded_text;
    $plain_text             =~ s/\0*$//s;
    return $plain_text;
}

# given a timestamp, returns seconds-since-epoch (unixtime). takes anything
# Date::Manip does, or passes through a unixtime. if a second parameter is
# given, it is taken as the time-of-day to use with only the date of the first
# parameter used.
sub str2time {
    my $reference = shift;
    my $offset = shift;

    return undef unless defined $reference;

    my $time;
    if ($reference =~ /^\d{10}$/) {
        # seconds since unix epoch
        $time = ParseDateString("epoch $reference");
    }
    elsif ($reference =~ /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$/) {
        # mysql integer date: YYYYMMDDHHMMSS
        $time = ParseDateString("$1-$2-$3 $4:$5:$6 UTC");
    }
    else {
        $time = ParseDateString($reference);
    }
    return undef unless $time;

    if (defined $offset) {
        return UnixDate(Date_SetTime($time, $offset), '%s');
    }
    else {
        return UnixDate($time, '%s');
    }
}

sub str2midnight {
    return str2time(shift, '00:00');
}

sub time2date {
    return strftime '%F', localtime shift;
}

sub printable_interval {
    my $t = shift; # seconds
    my $secs = int($t % 60);
    $t = ($t-$secs) / 60; # minutes
    my $mins = int($t % 60);
    $t = ($t-$mins) / 60; # hours
    my $hours = int($t % 24);
    $t = ($t-$hours) / 24; # days
    my $days = int($t % 7);
    $t = ($t-$days) / 7; # weeks
    my $weeks = int $t;

    my $buf = '';
    $buf = sprintf '%' . ($mins  ? '02' : '' ) . 'ds',    $secs;
    $buf = sprintf '%' . ($hours ? '02' : '' ) . 'dm %s', $mins,    $buf if $mins;
    $buf = sprintf '%' . ($days  ? '02' : '' ) . 'dh %s', $hours,   $buf if $hours;
    $buf = sprintf '%d day%s, %s',  $days,  ($days==1 ? '' : 's'),  $buf if $days;
    $buf = sprintf '%d week%s, %s', $weeks, ($weeks==1 ? '' : 's'), $buf if $weeks;
    return $buf;
}

use constant SECONDS => 1;
use constant MINUTES => 60 * SECONDS;
use constant HOURS   => 60 * MINUTES;
use constant DAYS    => 24 * HOURS;
use constant WEEKS   => 7  * DAYS;
use constant MONTHS  => 30 * DAYS;
use constant YEARS   => 52 * WEEKS;

sub fuzzy_interval {
    my $post_age = shift;
    if ($post_age < 1) {
        return 'Now';
    }
    elsif ($post_age > 5*YEARS) {
        return 'About' . _round($post_age/YEARS) . 'years';
    }
    elsif ($post_age > 12*MONTHS) {
        # month bins: 11 14 18 23 30 39 51 67
        return 'About' . round_to_nearest_log($post_age/MONTHS,  1.3) . 'months';
    }
    elsif ($post_age > 2*WEEKS) {
        # week bins: 2 3 4 5 6 8 11 14 18 23 30 39 51
        return 'About' . round_to_nearest_log($post_age/WEEKS,   1.3) . 'weeks';
    }
    elsif ($post_age > 3*DAYS) {
        # day bins: 3 4 5 8 11 15
        return 'About' . round_to_nearest_log($post_age/DAYS,    1.4) . 'days';
    }
    elsif ($post_age > 3*HOURS) {
        # hour bins: 3 4 5 8 11 15 21 29 40 57 79
        return 'About' . round_to_nearest_log($post_age/HOURS,   1.4) . 'hours';
    }
    elsif ($post_age > 5*MINUTES) {
        # minute bins: 5 8 11 17 26 38 58 86 130 195
        return 'About' . round_to_nearest_log($post_age/MINUTES, 1.5) . 'minutes';
    }
    else {
        # second bins: 1 2 4 8 16 32 64 128 256
        return 'About' . round_to_nearest_log($post_age/SECONDS, 2.0) . 'seconds';
    }
}

sub _round { return sprintf '%.f', $_[0]; }

# bin values on log scale
sub round_to_nearest_log {
    my ($value, $base) = @_;
    return _round($base ** _round(log($value) / log($base)));
}

sub commify {
    my $str = shift;
    1 while $str =~ s/^(\d+)(\d{3})/$1,$2/;
    return $str;
}

sub mtime { (stat shift)[9] }

1;
