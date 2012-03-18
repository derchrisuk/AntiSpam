package SpamSvc::Serotype::Rules;

use strict;
use warnings;

use Carp;
use SpamSvc::Connector ':all';
use SpamSvc::Serotype::Util qw/count_uris count_uris_schemeless/;

sub new {
    my $class = shift;
    my $ref = ref $class || $class;

    my $self = bless {}, $class;

    $self->{rules} = {

        brief => sub {
            my $data = shift;

            return $HAM if
                # no url field
                !$data->{params}{comment_author_url} &&
                # body is short
                length $data->{params}{comment_content} < $data->{settings}{max_length} &&
                # no urls in body
                count_uris_schemeless($data->{params}{comment_content}) == 0;

            return undef;
        },

    };

    return $self;
}

sub test {
    my $self = shift;
    my $rule = shift;
    my $data = shift;
    return $self->{rules}{$rule}->($data);
}

1;
