package SpamSvc::Serotype::Util::Encode;

use strict;
use warnings;

use Encode;

require Encode::Detect::Detector;
require Encode::CN;
require Encode::JP;
require Encode::KR;
require Encode::TW;
require Encode::HanExtra;
require Encode::JIS2K;

Encode::Alias::define_alias( qr/^x-mac-(.+)$/i => '"Mac$1"' );

our $valid_utf8_regexp = qr/^(
     [\x{00}-\x{7f}]                                #   U+0000 - U+007F   ASCII
   | [\x{c2}-\x{df}][\x{80}-\x{bf}]                 #   U+0080 - U+07FF   non-overlong 2-byte
   |  \x{e0} [\x{a0}-\x{bf}][\x{80}-\x{bf}]         #   U+0800 - U+0FFF   excluding overlongs
   | [\x{e1}-\x{ec}\x{ee}\x{ef}][\x{80}-\x{bf}]{2}  #   U+1000 - U+CFFF   straight 3-byte
   |  \x{ed} [\x{80}-\x{9f}][\x{80}-\x{bf}]         #   U+D000 - U+D7FF   excluding surrogates
   |  \x{f0} [\x{90}-\x{bf}][\x{80}-\x{bf}]{2}      #  U+10000 - U+3FFFF  planes 1-3
   | [\x{f1}-\x{f3}][\x{80}-\x{bf}]{3}              #  U+40000 - U+FFFFF  planes 4-15
   |  \x{f4} [\x{80}-\x{8f}][\x{80}-\x{bf}]{2}      # U+100000 - U+10FFFF plane 16
  )*$/x;


sub is_valid_utf8 {
    ## there is a bug in 5.8.5 in the regexp engine
    return is_valid_utf8_alt($_[0])
        if $^V lt v5.8.6; 
    return ${ $_[0] } =~ $valid_utf8_regexp;
}

sub is_valid_utf8_alt {
    use warnings FATAL => 'utf8';
    eval {
        my @chars = unpack ("U0U*", ${ $_[0] });
    };
    return $@ ? 0 : 1;
}

sub detect {
    return 'utf8-assumed' if is_valid_utf8($_[0]);
    return Encode::Detect::Detector::detect(${ $_[0] });
}

sub from_alien_encoding {
    my ($blobref, $encoding) = @_;

    return unless $$blobref;
    return if ($encoding && $encoding eq 'utf8-assumed');
    return force_utf8($blobref) if ! $encoding;
    return force_utf8($blobref) if   $encoding =~ /utf-?8/i;
    return force_utf8($blobref) if   $encoding eq 'garbaged';

    my $e = Encode::find_encoding($encoding);
    return force_utf8($blobref) unless $e;

    Encode::from_to($$blobref, $encoding, 'utf-8-strict'); 
    return;
}

sub force_utf8 {
    no warnings 'utf8';
    Encode::from_to(${ $_[0] }, 'utf8', 'utf-8-strict', Encode::FB_DEFAULT); 
    return;
}

sub normalize {
    if (!is_valid_utf8($_[0])) {
        from_alien_encoding($_[0], detect($_[0]));
    }
    return;
}

# decodes http parameter structure as returned by CGI::Deurl::XS
sub decode_http_params {
    my $params = shift;
    my %decoded_params;
    while (my ($k, $v) = each %$params) {
        my $kd = $k;
        normalize(\$kd);
        if (ref $v eq 'ARRAY') {
            $decoded_params{$kd} = [@$v]; # make a copy of the scalars
            normalize(\$_) for @{ $decoded_params{$kd} };
        }
        else {
            normalize(\($decoded_params{$kd} = $v));
        }
    }
    return \%decoded_params;
}

1;
