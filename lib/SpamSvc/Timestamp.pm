package SpamSvc::Timestamp;

use Exporter;

use base 'Exporter';

our @EXPORT = qw/tstamp/;

# returns a timestamp like 'Thu Sep 27 17:16:57.978893 2007: '
sub tstamp
{
    my $now = Time::HiRes::time;
    my $time = scalar localtime $now;
    substr $time, 19, 0, sprintf '.%06d', 1_000_000*($now - int $now);
    return $time . ': ';
}

1;
