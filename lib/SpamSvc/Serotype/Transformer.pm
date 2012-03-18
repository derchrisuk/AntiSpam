package SpamSvc::Serotype::Transformer;

use strict;
use warnings;

use Date::Parse;
use Email::Valid;
use SpamSvc::Serotype::Util qw/count_uris str2time fuzzy_interval/;
use URI::Find;

=pod

=head1 NAME

SpamSvc::Serotype::Transformer - transform Akismet HTTP request into email message

=cut

our $UseUnknownHeaders = 0;

# adapted from Email::Simple::Header
sub _header_lines
{
    my ($key, $value) = @_;

    my $string = "$key: $value";

    if (length $string <= 78) {
        return $string;
    }
    else {
        my @folded;
        while ($string) {
            $string =~ s/^\s+//;
            if ($string =~ s/^(.{0,77})(\s|\z)//) {
                push @folded, (@folded ? ' ' : '' ) . $1;
            }
            else {
                push @folded, (@folded ? ' ' : '' ) . $string;
                last;
            }
        }
        return @folded;
    }
}

our @needed_params = qw{
    comment_author_email
    comment_author_url
    comment_author
    comment_content
    referrer
    user_agent
    user_ip
};

our @squishable_params = qw{
};

our @ignored_params = qw{
    permalink
    blog
};

our %handled_params = map {$_ => 1} qw/
    article_date
    comment_author
    comment_author_email
    comment_author_url
    comment_content
    comment_type
    tracking_page_content
    user_ip
/;

my $crlf = "\r\n";

sub format_message
{
    my ($params_orig, $api_key, $ip, $meta_info) = @_;

    # make a writable copy of params
    my %params = %$params_orig;

    # some parameters are "required" by protocol spec, so make an explicit note
    # that client omitted them if they're missing as they may be evidence of a
    # non-standard client
    for my $param (@needed_params) {
        $params{$param} ||= "unknown_serotype_${param}";
    }

    # some parameters are space-heavy and overwhelm the factor space out of
    # proportion to their utility. this condenses their values into fewer tokens
    for my $param (@squishable_params) {
        $params{$param} =~ tr/ ,/_/s if exists $params{$param};
    }

    # some parameters are specific to the client, not the asset submitter.
    # including these tends to associate particular clients with predominant
    # behavior of their submitters, which sounds somewhat reasonable but works
    # out to be overly prejudicial. so for now, we drop those.
    for my $param (@ignored_params) {
        delete $params{$param};
    }

    my $comment_author       = delete $params{comment_author};
    my $comment_author_email = delete $params{comment_author_email};

    # need to normalize From and To headers so that the backend filter(s) can
    # reliably interpret them.  we don't bother to create a strict RFC2822
    # address since only filters see the address, but just remove unsafe chars
    $comment_author         =~ tr/\/a-zA-Z0-9_\- !#$%&\'*+=?^`{|}~@.//cd;
    $comment_author_email   =~ tr/\/a-zA-Z0-9_\- !#$%&\'*+=?^`{|}~@.//cd;

    if (
        defined $comment_author_email &&                # if email is provided...
        $comment_author_email !~ /^\s*$/ &&             # ... and non-empty
        !Email::Valid->address($comment_author_email)   # ... but invalid
    ) {
        $meta_info->{ValidEmail} = 'false';
    }

    if (exists $params{article_date}) {
        my $article_time = str2time(delete $params{article_date});
        if (defined $article_time) {
            my $post_age = time() - $article_time;
            $meta_info->{post_age} = fuzzy_interval($post_age);
        }
    }

    my %extra_params;
    # optionally pass along additional headers that client provided but we
    # weren't expected. this is encouraged by akismet api document, and many
    # clients (inc MT::Akismet) do it.
    if ($UseUnknownHeaders) {
        for my $k (keys %params) {
            # these are handled specially below
            next if $handled_params{$k};

            # be very particular about header names
            my $header = $k;
            $header =~ tr/_/-/;
            $header =~ tr/a-zA-Z0-9\-//cd;
            $header = 'X-Serotype-' . ucfirst lc $header;

            my $value = substr $params{$k}, 0, 254;
            $value =~ tr/\x20-\x7e//cd; # untaint: strip non-printable-ascii
            $extra_params{$header} = $value;
        }
    }

    # caller supplied-headers (not client)
    for my $key (keys %$meta_info) {
        $meta_info->{"X-$key"} = delete $meta_info->{$key};
    }

    # count URIs in message
    my $uri_count = count_uris($params{comment_content} . ' ' . $params{comment_author_url});
    if ($uri_count >= 12) {
        # round to a power of two
        $uri_count = 'Approximately' . round_to_nearest_log($uri_count, 2);
    }

    # strip spaces from certain headers so they're only considered as single tokens
    for my $header (qw//) {
        $params{$header} =~ s/\s//g;
    }

    my @headers = (
        #'Content-Type'  => 'text/plain; charset=UTF-8; format=flowed',
        #'Date'          => strftime('%a, %d %b %Y %H:%M:%S %z', localtime time), # rfc2822 time format
        'From'          => qq{<$comment_author_email>},
        'FromName'      => qq{"$comment_author"},
        #'To'            => qq{"$blog" <$api_key>},
        #'To'            => qq{<$api_key>},
        #'Subject'       => $params{comment_type},# . ' ' . $params{permalink},
        'Received'      => $params{user_ip},
        #'User-Agent'    => $params{user_agent},
        #'X-Referer-URL' => $params{referrer},
        'X-URL-Count'   => $uri_count,
        %extra_params,
        %$meta_info,
    );

    my @pieces;

    my $email_text = '';
    for (my $i = 0; $i < @headers; $i+=2) {
        push @pieces, _header_lines($headers[$i], $headers[$i+1]);
    }
    push @pieces, '';

    push @pieces, $params{comment_content};

    push @pieces, " $params{comment_author_url}";

    if ($params{comment_type} eq 'trackback' && defined $params{tracking_page_content}) {
        push @pieces,
            '',
            'tracking_page_content_follows',
            '',
            $params{tracking_page_content};
    }

    return join '', map {$_, $crlf} @pieces;
}

sub _round { return sprintf '%.f', $_[0]; }

1;
