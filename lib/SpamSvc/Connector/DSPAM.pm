package SpamSvc::Connector::DSPAM;

use strict;
use warnings;

use SpamSvc::Connector ':all';

use base 'SpamSvc::Connector::HeaderClassifier';

=pod

=head1 NAME

SpamSvc::Connector::DSPAM - determine spamminess via dspam(1)

=cut

my %response_map = (
    'Innocent'      => $HAM,
    'Whitelisted'   => $HAM,
    'Spam'          => $SPAM,
);

sub new {
    my $class = shift;
    my $self = {@_};
    chomp($self->{bin} = `which dspam 2>/dev/null`)
        unless defined $self->{bin};
    $self->{user} ||= 'typepad';
    bless $self, $class;
    return $self;
}

sub user {
    my $self = shift;
    $self->{user} = $_[0] if @_;
    return $self->{user};
}

sub classify_args {
    my $self = shift;
    return (
        '--mode=notrain',
        '--user', $self->{user},
        '--deliver=stdout',
    );
}

sub train_ham_args {
    my $self = shift;
    return (
        '--mode=toe',
        '--user', $self->{user},
        '--class=innocent',
        '--deliver=stdout',
    );
}

sub train_spam_args {
    my $self = shift;
    return (
        '--mode=toe',
        '--user', $self->{user},
        '--class=spam',
        '--deliver=stdout',
    );
}

sub process_line {
    my $self = shift;
    my $line_ref = shift;

    print STDERR $$line_ref if $self->{debug} && /X-DSPAM/;

    # example dspam(1) outputs:
    # X-DSPAM-Result: Spam
    # X-DSPAM-Result: Innocent
    # X-DSPAM-Confidence: 0.8986
    # X-DSPAM-Probability: 1.0000

    if ($$line_ref
        =~ /
            X-DSPAM-Result:
            \s+
            (Innocent|Whitelisted|Spam)
        /x
    ) {
        $self->{last_rating} = $response_map{$1};
        return 0;
    }

    if ($$line_ref
        =~ /
            X-DSPAM-Confidence:
            \s+
            ([0-9.-]+)
        /x
    ) {
        $self->{last_confidence} = $1;
        return 0;
    }

    if ($$line_ref
        =~ /
            X-DSPAM-Probability:
            \s+
            ([0-9.-]+)
        /x
    ) {
        $self->{last_probability} = $1;
        return 1;
    }

    return 0; # keep parsing
}

1;
