package Mail::DSPAM::Client;

use strict;
use warnings;

use Carp;
use Net::DLMTP 0.03;

our $VERSION = "0.15";

sub new {
    my $that 	= shift;
    my $class 	= ref $that || $that;
    my %params	= @_;

    my $self = \%params;

    croak 'DSPAM client ID required'       unless defined $self->{client_id};
    croak 'DSPAM client password required' unless defined $self->{client_pass};

    $self->{server}         ||= '127.0.0.1';

    $self->{port}           ||= 24
        unless $self->{server} =~ m{^/};

    $self->{train_mode}     ||= 'toe';
    $self->{source}         ||= 'error';

    $self->{username}       = sprintf "<%s\@%s>", $self->{client_pass}, $self->{client_id};

    $self->{lmtp_opts}      ||= {
        Timeout => 10,
    };

    return bless $self, $class;
}

sub _to {
    my $self = shift;
    my $user = shift;
    return "<$user>";
}

sub classify {
    my $self    = shift;
    my $user    = shift;
    my $message = shift;

    my $dlmtp = Net::DLMTP->new(
        $self->{server},
        $self->{port},
        %{ $self->{lmtp_opts} }
    );

    croak "failed to create Net::DLMTP" unless $dlmtp;

    my $from = sprintf qq{%s DSPAMPROCESSMODE="--client --process --mode=notrain --deliver=innocent,spam --stdout"},
        $self->{username};

    $dlmtp->mail($from);
    $dlmtp->to($self->_to($user));
    $dlmtp->data($message);

    $dlmtp->read_rest();
    return $dlmtp->data_response_lines();
}

sub process {
    my $self    = shift;
    my $user    = shift;
    my $message = shift;

    my $dlmtp = Net::DLMTP->new(
        $self->{server},
        $self->{port},
        %{ $self->{lmtp_opts} }
    );

    croak "failed to create Net::DLMTP" unless $dlmtp;

    my $from = sprintf qq{%s DSPAMPROCESSMODE="--client --process --mode=%s --deliver=innocent,spam --stdout"},
        $self->{username}, $self->{train_mode};

    $dlmtp->mail($from);
    $dlmtp->to($self->_to($user));
    $dlmtp->data($message);

    $dlmtp->read_rest();
    return $dlmtp->data_response_lines();
}

# NB: training unprocessed message will fail unless TrainPristine is enable in dspam conf
sub train {
    my $self    = shift;
    my $user    = shift;
    my $class   = shift;
    my $message = shift;

    my $dlmtp = Net::DLMTP->new(
        $self->{server},
        $self->{port},
        %{ $self->{lmtp_opts} }
    );

    croak "failed to create Net::DLMTP" unless $dlmtp;

    my $from = sprintf qq{%s DSPAMPROCESSMODE="--client --process --mode=%s --deliver=innocent,spam --stdout --source=%s --class=%s"},
        $self->{username}, $self->{train_mode}, $self->{source}, $class;

    $dlmtp->mail($from);
    $dlmtp->to($self->_to($user));
    $dlmtp->data($message);

    $dlmtp->read_rest();
    return $dlmtp->data_response_lines();
}

1;

__END__

=head1 NAME

Mail::DSPAM::Client - DSPAM Local Mail Transfer Protocol Client

=head1 SYNOPSIS

    use Net::DLMTP;
    
    # Constructors
    $lmtp = Net::DLMTP->new('dspamdaemon', 2003);
    $lmtp = Net::DLMTP->new('dspamdaemon', 2003, Timeout => 60);

=head1 DESCRIPTION

Net::DLMTP partially implements the DLMTP protocol, which is the internal
dialect of LMTP shared by the dspam(1) daemon and dspamc(1).

At present, Net::DLMTP inherits all behavior from Net::LMTP, except that where
Net::LMTP attempts to normalize addresses passed to mail() and friends,
Net::DLMTP passes them unmodified to the server. This allows passing
DSPAMPROCESSMODE parameters in the address without resorting to avoiding
mail().

=head1 EXAMPLES

This example prints the mail domain name of the LMTP server known as 
dspamdaemon with LMTP service on port 2003:

    #!/usr/local/bin/perl -w
    
    use Net::DLMTP;
    
    my $lmtp = Net::DLMTP->new('dspamdaemon', 2003);
    print $lmtp->domain,"\n";
    $lmtp->quit;

This example sends a small message to the postmaster at the SMTP server
known as dspamdaemon:

    #!/usr/local/bin/perl -w
    
    use Net::DLMTP;
    
    my $lmtp = Net::DLMTP->new('dspamdaemon', 2003);
    
    $lmtp->mail($ENV{USER});
    $lmtp->to('postmaster');
    
    $lmtp->data();
    $lmtp->datasend("To: postmaster\n");
    $lmtp->datasend("\n");
    $lmtp->datasend("A simple test message\n");
    $lmtp->dataend();
    
    $lmtp->quit;

=head1 SEE ALSO

L<Net::LMTP>

=head1 AUTHOR

Adam Thomason <athomason@sixapart.com>

=head2 THANKS

Special thanks to Les Howard and others responsible for Net::LMTP.

=head1 COPYRIGHT

Copyright (c) 2007 Six Apart <cpan@sixapart.com>. All rights reserved.
This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
