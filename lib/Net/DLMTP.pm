package Net::DLMTP;

use strict;
use warnings;

use Net::LMTP 0.04;
use base 'Net::LMTP';

our $VERSION = "0.04";

sub new {
    my $class = shift;
    my $type = ref($class) || $class;

    my $self = $type->SUPER::new(@_);
    return undef unless defined $self;
    bless $self, $type;

    return $self;
}

# DLMTP doesn't strictly conform to Net::Cmd-type protocol
# (ie. '123 response') since it can spew free text after DATA terminates.
# Therefore we keep special track of stuff that comes back after DATA.
sub data_response_lines {
    my $self = shift;
    my $value = shift;

    my $ref;
    if ($value) {
        $ref = ${*$self}{'data_response_lines'} = $value;
    }
    else {
        $ref = ${*$self}{'data_response_lines'} || [];
    }

    return wantarray() ? @$ref : $ref;
}

sub dataend {
    my $self = shift;
    $self->data_response_lines([]);
    return $self->SUPER::dataend(@_);
}

# Net::Cmd::dataend handles only one line. depending on what was asked of
# dspam, it may return either just that one line or lots after DATA finishes.
# call this method in the latter case to continue parsing until a /^\.$/
# sequence is seen.
sub read_rest {
    my $self = shift;
    while (my $line = $self->getline()) {
        $self->parse_response($line);
        last if $line =~ /^\.$/;
    }
}

sub parse_response
{
    my $self = shift;
    my $response = shift;
    push @{ $self->data_response_lines() }, $response; # XXX shouldn't do this until after DATA cmd
    if ($response !~ /^(\d{3})/) {
        # return a fake 200 so Net::Cmd is happy
        $response = "200 $response";
    }
    $self->SUPER::parse_response($response, @_);
}

# don't touch the arg
sub _addr {
    my $self = shift;
    return shift;
}

1;

__END__

=head1 NAME

Net::DLMTP - DSPAM Local Mail Transfer Protocol Client

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
