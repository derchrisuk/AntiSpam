package SpamSvc::Connector::DSPAM::Client;

use strict;
use warnings;

use Carp;
use Mail::DSPAM::Client;
use SpamSvc::Connector ':all';
use SpamSvc::Connector::DSPAM;

use base qw{ Mail::DSPAM::Client SpamSvc::Connector };

=pod

=head1 NAME

SpamSvc::Connector::DSPAM::Client - determine spamminess by connecting to dspam daemon

=cut

my %response_map = (
    'Innocent'      => $HAM,
    'Whitelisted'   => $HAM,
    'Spam'          => $SPAM,
);

# store data inside-out
my %_stash;
sub stash {
    my $self = shift;
    return $_stash{$self} ||= {};
}

sub new {
    my $that = shift;
    my $class = ref $that || $that;
    my %params = @_;
    my $user = delete $params{user};

    my $self = Mail::DSPAM::Client->new(%params);
    return undef unless $self;

    bless $self, $class;
    $self->user($user) if defined $user;
    return $self;
}

sub user {
    my $self = shift;
    my $user = shift;

    my $stash = $self->stash;

    if (defined $user) {
        $stash->{user} = $user;
    }
    return $stash->{user};
}

sub get_processed_email {
    my $self    = shift;
    my $message = shift;

    return $self->Mail::DSPAM::Client::process($self->user, $message);
}

sub get_classified_email {
    my $self    = shift;
    my $message = shift;

    return $self->Mail::DSPAM::Client::classify($self->user, $message);
}

sub get_factors {
    my $self    = shift;

    return $self->{last_factors};
}

sub _extract_rating {
    my $self = shift;

    $self->{last_rating} =
    $self->{last_confidence} =
    $self->{last_probability} =
        undef;

    $self->{_reading_factors} = 0;
    $self->{last_factors} = undef;

    for my $line (@_) {
        last if $self->process_line(\$line);
    }

    return wantarray ? ($self->{last_rating}, $self->{last_confidence}) : $self->{last_rating};
}

sub classify_email {
    my $self    = shift;
    my $message = shift;

    return $self->_extract_rating($self->get_classified_email($message));
}

sub train_ham {
    my $self = shift;
    return $self->_extract_rating($self->Mail::DSPAM::Client::train($self->user, 'innocent', @_));
}

sub train_spam {
    my $self = shift;
    return $self->_extract_rating($self->Mail::DSPAM::Client::train($self->user, 'spam', @_));
}

sub process_line {
    my $self = shift;
    my $line_ref = shift;

    print STDERR $$line_ref if $self->{debug};

    return 0 unless $$line_ref =~ /^X-DSPAM/ || $self->{_reading_factors};

    if ($$line_ref =~ m/^X-DSPAM-Result:\s(Innocent|Whitelisted|Spam)/) {
        $self->{last_rating} = $response_map{$1};
    }
    elsif ($$line_ref =~ m/^X-DSPAM-Confidence:\s([0-9.-]+)/) {
        $self->{last_confidence} = $1;
    }
    elsif ($$line_ref =~ m/^X-DSPAM-Probability:\s([0-9.-]+)/) {
        $self->{last_probability} = $1;
    }
    elsif ($$line_ref =~ m/^X-DSPAM-Factors:\s(\d+)/) {
        $self->{_reading_factors} = 1;
        $self->{last_factors} = {}
    }
    elsif ($self->{_reading_factors} && $$line_ref =~ m{
            ^\t         # after X-DSPAM-Factors line, factors are preceded by a tab
            ([^,]+)     # factor text. XXX this will fail on factors containing commas; if dspam tokenizer changes that's bad
            ,\s         # factor and prob separated by comma and space
            ([0-9.]+)   # factor spam probability
            (,?)        # all but last factor have a trailing comma
            $
        }x
    ) {
        $self->{last_factors}{$1} = $2;
        $self->{_reading_factors} = 0 unless $3 eq ',';
    }
    elsif ($$line_ref =~ /^$/) {
        # end of headers, stop parsing
        return 1;
    }

    return 0; # keep parsing
}

1;
