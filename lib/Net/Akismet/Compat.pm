package Net::Akismet::Compat;

=head1 NAME

Net::Akismet::Compat - Subclass of Net::Akismet that can query any Akismet-compatible server

=cut

use 5.006;
use warnings;
use strict;
use integer;

use Carp;
use HTTP::Request::Common;
use LWP::UserAgent;
use Net::Akismet 0.03;

use base 'Net::Akismet';

our $VERSION = '0.14';

=head1 SYNOPSIS

    my $akismet_alternative = Net::Akismet::Compat->new(
            KEY => 'secreter-baba-API-key',
            URL => 'http://example.blog.net/',
            SERVER => 'rest.akismet.com',
        ) or die('Key verification failure!');

=head1 METHODS

=over 8

=item new()

    Net::Akismet::Compat->new(PARAM => ...);

Acceptable parameters:

=over 4

=item SERVER

The server/domain to make queries to. Key verification queries are sent to
SERVER, and queries/reports are sent to KEY.SERVER. For example, imagine
myspamchecker.com offers an Akismet-compatible service at
akismet.myspamchecker.com and has assigned you an API key of 'myapikey'; key
validation requests are sent to http://akismet.myspamchecker.com while messages
are sent to http://myapikey.akismet.myspamchecker.com. Standard server:port
syntax may also be used if the service doesn't run on port 80.

If SERVER is omitted the default of 'rest.akismet.com' is used.

=item APIVER

Version of the Akismet API being used. Defaults to 1.1.

=item KEY

=item URL

=item USER_AGENT

These parameters are used as in Net::Akismet-E<gt>new().

=item KEY_BY_DOMAIN

If true, key is passed by hostname as described above (i.e., KEY.SERVER). If
false, requests are sent directly to SERVER and KEY is sent as an additional
header. Defaults to true.

=item VERIFY_KEY

If true, new() will contact SERVER and validate KEY. If the key cannot be
validated or the server indicates it is invalid, new will croak. Defaults to
true.

=item STRICT

If true (the default), calling new() without KEY or URL parameters, or calling 
check(), spam(), or ham() without a USER_IP or COMMENT_USER_AGENT will result
in a fatal error.

=back

=cut

my $UA_SUFFIX   = "Akismet Perl/$VERSION";

sub new {

    my $that    = shift;
    my $class   = ref $that || $that;
    my %params  = @_;

    # sadly we can't use Net::Akismet->new since it returns undef if key
    # verification fails, but we can't make it use a different server for
    # that check. therefore must replicate its behavior...
    my $self = \%params;

    $self->{ua} ||= LWP::UserAgent->new();

    $self->{STRICT}++ unless defined $self->{STRICT};

    if ($self->{STRICT}) {
        croak "no KEY provided" unless $self->{KEY};
        croak "no URL provided" unless $self->{URL};
    }

	my $agent = "$UA_SUFFIX ";
	$agent = "$params{USER_AGENT} $agent" if $params{USER_AGENT};
	$self->{ua}->agent($agent);

    $self->{SERVER} = 'rest.akismet.com'
        unless exists $self->{SERVER};

    $self->{APIVER} = '1.1'
        unless exists $self->{APIVER};

    $self->{KEY_BY_DOMAIN} = 1
        unless exists $self->{KEY_BY_DOMAIN};

    $self->{VERIFY_KEY} = 1
        unless exists $self->{VERIFY_KEY};

    bless $self, $class;

    if ($self->{VERIFY_KEY} && (!defined $self->{ua} || !$self->_verify_key())) {
        croak "key verification failed";
    }
    else {
        return $self;
    }
}

=item $service-E<gt>ua()

Getter/setter for the LWP::UserAgent which connects to the antispam service.

=cut

sub ua {
    my $self = shift;
    my $ua   = shift;
    $self->{ua} = $ua if defined $ua;
    return $self->{ua};
}

sub _verify_key {

    my $self     = shift;


    my $response = $self->{ua}->request(
        POST "http://$self->{SERVER}/$self->{APIVER}/verify-key", 
        [
            key     => $self->{KEY},
            blog    => $self->{URL},
        ]
    );

    croak "no response" unless $response;
    croak "response not successful" unless $response->is_success;
    croak "key invalid" unless $response->content() eq 'valid';
        
    return 1;
}

sub _submit {

    my $self = shift;

    my $action = shift || 'comment-check';

    my $comment = shift;

    if ($self->{STRICT}) {
        croak "no USER_IP provided" unless $comment->{USER_IP};
        croak "no COMMENT_USER_AGENT provided" unless $comment->{COMMENT_USER_AGENT};
    }

    my @data = (
        blog                    => $self->{URL},
        user_ip                 => delete $comment->{USER_IP},
        user_agent				=> delete $comment->{COMMENT_USER_AGENT},
        referrer                => delete $comment->{REFERRER},
        permalink               => delete $comment->{PERMALINK},
        comment_type            => delete $comment->{COMMENT_TYPE},
        comment_author          => delete $comment->{COMMENT_AUTHOR},
        comment_author_email    => delete $comment->{COMMENT_AUTHOR_EMAIL},
        comment_author_url      => delete $comment->{COMMENT_AUTHOR_URL},
        comment_content         => delete $comment->{COMMENT_CONTENT},
    );

    push @data, (lc $_ => $comment->{$_}) for keys %$comment;

    my $request;
    if ($self->{KEY_BY_DOMAIN}) {
        $request = POST "http://$self->{KEY}.$self->{SERVER}/$self->{APIVER}/$action", \@data;
    }
    else {
        push @data, (key => $self->{KEY});
        $request = POST "http://$self->{SERVER}/$self->{APIVER}/$action", \@data;
    }

    my $response = $self->{ua}->request($request);

    $self->{response_obj} = $response;

    croak 'no response received' unless $response;

    $self->{response} = $response->content();

    croak 'response not successful: ' . $response->as_string
        unless $response->is_success;

    return 1;
}

=item $service-E<gt>get_body()

Returns the body of the last HTTP response.

=cut

sub get_body {
    my $self = shift;
    return undef if !$self->{response_obj};
    return $self->{response_obj}->content;
}

=item $service-E<gt>get_headers()

Returns a hash (or hashref in scalar context) of all HTTP response headers from the last query.

=cut

sub get_headers {
    my $self = shift;
    return undef if !$self->{response_obj};
    return wantarray ? %{ $self->{response_obj}->headers() } : $self->{response_obj}->headers();
}

=item $service-E<gt>get_header($header)

Returns the value of the named HTTP response header from the last query.

=cut

sub get_header {
    my $self = shift;
    return undef if !$self->{response_obj};
    my $header = lc shift;
    return $self->{response_obj}->headers->{$header};
}

1;

=back

All other methods and behavior are inherited from Net::Akismet.

=head1 AUTHOR

Adam Thomason E<lt>athomason@sixapart.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2008 by Six Apart E<lt>cpan@sixapart.comE<gt>

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself, either Perl version 5.8.7 or, at your option, any later version of Perl 5 you may have available.

=cut
