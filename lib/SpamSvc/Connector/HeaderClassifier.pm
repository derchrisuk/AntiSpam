package SpamSvc::Connector::HeaderClassifier;

use strict;
use warnings;

use Carp;
use IPC::Open2;
use SpamSvc::Connector ':all';

use base 'SpamSvc::Connector';

=pod

=head1 NAME

SpamSvc::Connector::HeaderClassifier - abstract base class for command line
mail filters that take mail input on stdin and output the message with
filter-specific injected headers on stdout

=cut

sub new {
    my $class = shift;
    my $self = {};
    bless $self, $class;
    return $self;
}

sub status_header_matcher {
    croak "status_header_matcher only available in concrete subclasses";
}

sub classify_args {
    return ();
}

sub train_ham_args {
    croak "train_ham_args only available in concrete subclasses";
}

sub train_spam_args {
    croak "train_spam_args only available in concrete subclasses";
}

sub process_line {
    croak "process_line only available in concrete subclasses";
}

sub bin {
    my $self = shift;
    $self->{bin} = $_[0] if @_;
    return $self->{bin};
}

sub _execute {
    my $self = shift;
    my $email = shift;
    my @extra_args = @_;

    my $pipe_failed = 0;
    local $SIG{PIPE} = sub { $pipe_failed++ };

    my ($pid, $reader, $writer);
    eval {
        $pid = open2($reader, $writer, $self->{bin}, $self->classify_args(), @extra_args);
    };

    if ($@) {
        carp "couldn't run $self->{bin}: $@";
        return $ERROR;
    }

    if ($pipe_failed) {
        carp "couldn't write to $self->{bin}: $!";
        return $ERROR;
    }

    #printf STDERR "writing to %s:\n%s\n", join(' ', $self->{bin}, $self->classify_args()), $email;

    print $writer $email;
    close $writer;

    $self->{last_rating} = $ERROR;
    while (<$reader>) {
        last if $self->process_line(\$_);
    }

    close $reader;

    waitpid $pid, 0;
}

sub classify_email {
    my $self = shift;
    $self->_execute(@_);
    return $self->{last_rating};
}

sub train_ham {
    my $self = shift;
    $self->_execute(@_, $self->train_ham_args());
}

sub train_spam {
    my $self = shift;
    $self->_execute(@_, $self->train_spam_args());
}

1;
