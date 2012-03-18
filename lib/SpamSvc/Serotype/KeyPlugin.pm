package SpamSvc::Serotype::KeyPlugin;

=head1 NAME

SpamSvc::Serotype::KeyPlugin

=head1 SYNOPSIS

Implementations of the KeyPlugin interface are plugins to Serotype's apikey
lookup system. Plugins implementing this class are given an opportunity to
"claim" newly seen api keys. Subsequent operations made using that key consult
the claiming plugin for authorization.

=head1 RETURN CONSTANTS

KeyPlugin exports some constants which hook methods may return to indicate return value:

=over 4

=item KEY_ALLOW

The operation should be allowed.

=item KEY_DENY

The operation should not be allowed.

=item KEY_CLAIMED

Specific to C<inspect_new_key> , this indicates that the plugin wishes to be
consulted on uses of the given api key.

=back

=cut

use strict;
use warnings;

use Carp;
use Exporter;

use SpamSvc::Connector qw/ $ERROR $SPAM $HAM $UNKNOWN /;

use base 'Exporter';

our @EXPORT = qw/ KEY_ALLOW KEY_DENY KEY_CLAIMED /;

use constant KEY_ALLOW   => 0;
use constant KEY_DENY    => 1;
use constant KEY_CLAIMED => 2;

=head1 CLASS METHODS

=over 4

=item new

Creates a new KeyPlugin object, just an empty hashref.

=cut

sub new {
    my $class = shift;
    my $ref = ref $class || $class;
    my $self = {};
    bless $self, $class;
    return $self;
}

=item special_class_name

Returns a unique string identifying the plugin. Must be overriden by subclasses.

=cut

sub special_class_name {
    my $class = shift;
    croak "$class didn't implement special_class_name";
    return undef;
}

=back

=head1 HOOKS

The following hook methods maybe be implemented by subclasses of KeyPlugin to
be called by Serotype.

=over 4

=item inspect_new_key

When an unknown api key is presented to serotype, each implementing plugin's
C<inspect_new_key> method is called. If the method returns C<KEY_CLAIMED>, this
plugin's ID associated with the key. If it returns C<KEY_DENY>, the key is not
created and the originating REST request fails. If it returns C<KEY_ALLOW>,
this plugin does not claim the key and remaining plugins are allowed the
opportunity to do so.

=cut

sub inspect_new_key {
    my $self        = shift;
    my $api_key     = shift;
    my $key_props   = shift;
    my $config      = shift;
    my $ip          = shift;
    return KEY_ALLOW;
}

=item check_ip

Before any query operation (comment-check, submit-spam, submit-ham,
verify-key), this method is passed the api key, the key data object, and the
requesting IP address. The method may returned KEY_ALLOW or KEY_DENY as
appropriate.

=cut

sub check_ip {
    my $self        = shift;
    my $api_key     = shift;
    my $key_props   = shift;
    my $ip          = shift;

    return KEY_ALLOW;
}

=item query_content_check

Before any content checks are done, this method is called with the generated
email text. THe method may return UNKNOWN, SPAM, or HAM.

=cut

sub query_pre_content_check {
    my $self        = shift;
    my $api_key     = shift;
    my $key_props   = shift;
    my $email_ref   = shift;

    return $UNKNOWN;
}

1;

=back

=cut
