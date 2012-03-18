package SpamSvc::Connector;

use strict;
use warnings;

use Carp;
use Exporter;
use Readonly;

use base 'Exporter';

our %EXPORT_TAGS = (
    'all'       => [ qw{printable_rating $ERROR $HAM $SPAM $UNKNOWN} ]
);

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

=pod

=head1 NAME

SpamSvc::Connector - abstract base class for SpamSvc::Connector mail filters

=cut

Readonly our $ERROR     => 0;
Readonly our $HAM       => 1;
Readonly our $SPAM      => 2;
Readonly our $UNKNOWN   => 3;

Readonly my %_printable_rating => (
    $ERROR      => 'error',
    $HAM        => 'ham',
    $SPAM       => 'spam',
    $UNKNOWN    => 'unknown',
);

sub printable_rating {
    my $numeric_rating = shift;
    return $UNKNOWN unless defined $numeric_rating;
    croak "invalid rating: $numeric_rating"
        unless exists $_printable_rating{$numeric_rating};
    return $_printable_rating{$numeric_rating};
}

sub classify_email {
    my $self = shift;
    croak "classify_email only available in concrete subclasses";
    return $self->{last_rating};
}

sub get_confidence {
    my $self = shift;
    return defined $self->{last_confidence} ? $self->{last_confidence} : undef;
}

sub train_ham {
    my $self = shift;
    croak "train_ham only available in concrete subclasses";
}

sub train_spam {
    my $self = shift;
    croak "train_spam only available in concrete subclasses";
}

1;
