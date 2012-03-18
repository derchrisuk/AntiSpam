package Net::Akismet::TPAS;

=head1 NAME

Net::Akismet::TPAS - Convenience methods for accessing TypePad Antispam
extensions to the Akismet protocol.

=cut

use 5.006;
use warnings;
use strict;

use Carp;

use base 'Net::Akismet::Compat';

our $VERSION = '0.13';

=head1 SYNOPSIS

    my $service = Net::Akismet::TPAS->new(
        KEY => 'secreter-baba-API-key',
        URL => 'http://example.blog.net/',
        SERVER => 'api.antispam.typepad.com',
    ) or die('Key verification failure!');

=cut

=head1 METHODS

=over 8

=item Net::Akismet::TPAS-E<gt>new()

Constructor; takes the same parameters as Net::Akismet::Compat->new()

=cut

sub new {
    my $that    = shift;
    my $class   = ref $that || $that;

    my $self = Net::Akismet::Compat->new(@_);

    return bless $self, $that;
}

=item $service-E<gt>get_confidence()

Returns the antispam service's confidence value in the result it returned.
Confidence--if provided by the server--is in the range 0.0-1.0 for both spam
and ham.

=cut

sub get_confidence {
    my $self = shift;
    my $conf = $self->get_header('X-Spam-Confidence');
    if (defined $conf) {
        return $conf;
    }
    else {
        return 1.0;
    }
}

=item $service-E<gt>certain()

Returns true or false value depending on whether the spam service claimed to be
certain about its result. This is an adjunct to the confidence value; the
definition of certainty is up to the service.

=cut

sub certain {
    my $self = shift;
    my $certain = $self->get_header('X-Spam-Certain');
    if (!defined $certain) {
        return 1;
    }
    elsif ($certain eq 'true') {
        return 1;
    }
    elsif ($certain eq 'false') {
        return 0;
    }
    else {
        return 1;
    }
}

1;

=back

All other methods and behavior are inherited from Net::Akismet.

=head1 AUTHOR

Adam Thomason E<lt>athomason@sixapart.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2008 by Six Apart E<lt>cpan@sixapart.comE<gt>

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself, either Perl version 5.8.5 or, at your option,
any later version of Perl 5 you may have available.

=cut
