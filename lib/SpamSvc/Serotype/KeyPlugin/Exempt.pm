package SpamSvc::Serotype::KeyPlugin::Exempt;

use strict;
use warnings;

# members of the 'exempt' class always receive a query response of ham. set the
# class flag of your user column for test apikeys which should always be
# hammed.

use SpamSvc::Serotype::KeyPlugin;
use SpamSvc::Connector '$HAM';

sub new {
    my $class = shift;
    my $ref = ref $class || $class;
    my $self = SpamSvc::Serotype::KeyPlugin->new();
    bless $self, $class;
    return $self;
}

sub special_class_name {
    my $class = shift;
    return 'exempt';
}

sub inspect_new_key {
    return KEY_ALLOW;
}

sub check_ip {
    return KEY_ALLOW;
}

sub query_pre_content_check {
    return $HAM;
}

1;
