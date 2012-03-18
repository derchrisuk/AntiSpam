package SpamSvc::Connector::CRM114;

use strict;
use warnings;

use SpamSvc::Connector ':all';

use base 'SpamSvc::Connector::HeaderClassifier';

=pod

=head1 NAME

SpamSvc::Connector::CRM114 - determine spamminess via CRM114's mailfilter.crm

=cut

my %response_map = (
    'Good'          => $HAM,
    'SPAM'          => $SPAM,
    'UNSURE'        => $UNKNOWN,
);

sub new {
    my $class = shift;
    my $self = {@_};
    chomp($self->{bin} = `which crm 2>/dev/null`)
        unless defined $self->{bin};
    $self->{filter} ||= 'mailfilter.crm';
    bless $self, $class;
    return $self;
}

sub filter {
    my $self = shift;
    $self->{filter} = $_[0] if @_;
    return $self->{filter};
}

sub max_spam_pR {
    my $self = shift;
    $self->{max_spam_pR} = $_[0] if @_;
    return $self->{max_spam_pR};
}

sub min_ham_pR {
    my $self = shift;
    $self->{min_ham_pR} = $_[0] if @_;
    return $self->{min_ham_pR};
}

sub classify_args {
    my $self = shift;
    if (defined $self->{filter}) {
        return $self->{filter};
    }
    else {
        return ();
    }
}

sub train_ham_args {
    my $self = shift;
    return (
        $self->{filter},
        '--learn-nonspam',
    );
}

sub train_spam_args {
    my $self = shift;
    return (
        $self->{filter},
        '--learn-spam',
    );
}

sub process_line {
    my $self = shift;
    my $line_ref = shift;

    print STDERR $$line_ref if $self->{debug} && /X-CRM114/;

    # example crm(1) outputs:
    # X-CRM114-Status: UNSURE (-1.0895) This message is 'unsure'; please train it!
    # X-CRM114-Status: SPAM  ( pR: -11.0651 )
    # X-CRM114-Status: Good  ( pR: 12.8047 )

    # pR<-10 'SPAM', pR>10 'Good', other 'UNSURE'

    if ($$line_ref
        =~ /
            X-CRM114-Status:
            \s+
            (SPAM|Good|UNSURE)
            \s+
            \(
                \s*
                (?:
                    pR:
                    \s+
                )?
                \s*
                (
                    [0-9.-]+
                )
                \s*
            \)
        /x
    ) {
        my ($rating, $pR) = ($1, $2);

        if (defined $self->{max_spam_pR} && $pR <= $self->{max_spam_pR}) {
            $self->{last_rating} = $SpamSvc::Connector::HeaderClassifier::SPAM;
        }
        elsif (defined $self->{min_ham_pR} && $pR >= $self->{min_ham_pR}) {
            $self->{last_rating} = $SpamSvc::Connector::HeaderClassifier::HAM;
        }
        else {
            $self->{last_rating} = $response_map{$rating};
        }
        $self->{last_pR} = $pR;

        return 1; # stop parsing
    }

    return 0; # keep parsing
}


1;
