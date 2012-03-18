package SpamSvc::Serotype::Workers::Train;

use strict;
use warnings;

use Carp;
use List::Util qw/min max/;
use SpamSvc::Serotype::Workers::Client;
use SpamSvc::Connector ':all';
use SpamSvc::Timestamp;
use Storable qw/thaw/;
use Time::HiRes;

use base 'SpamSvc::Serotype::Workers::Client';

sub new # {{{
{
    my $class = shift;
    my $ref = ref $class || $class;

    my SpamSvc::Serotype::Workers::Train $self = SpamSvc::Serotype::Workers::Client->new(@_);
    bless $self, $class;

    $self->register_accounted_method(serotype_train => \&_train);

    return $self;
} # }}}

sub _train # {{{
{
    my SpamSvc::Serotype::Workers::Train $self = shift;
    my $job = shift;

    my $args = thaw($job->arg);

    my $key_data = $args->{key_data};

    # do we train?
    my $reputation_threshold;
    if ($self->{memcache}) {
        $reputation_threshold = $self->{memcache}->get('serotype:reputation_threshold');
        if (!defined $reputation_threshold) {
            $reputation_threshold = $self->{config}{reputation}{default_threshold};
            $self->{memcache}->set("serotype:reputation_threshold", $reputation_threshold);
        }
    }
    else {
        $reputation_threshold = $self->{config}{reputation}{default_threshold};
    }

    unless ($self->{config}{global_user_only}) {
        # always train user's dataset
        $self->_train_backend($key_data->[CLIENT_backend_id], $args->{disposition}, \$args->{email});
        $self->submit_task(serotype_update_log => {
            raw_id          => $args->{id},
            api_key         => $key_data->[CLIENT_api_key],
            trained_backend => 1,
        });
    }

    # train global dataset?
    my $accepted = $key_data->[CLIENT_trust] > $reputation_threshold;
    if ($accepted) {
        $self->_train_backend($self->{config}{global_username}, $args->{disposition}, \$args->{email});
        $self->submit_task(serotype_update_log => {
            raw_id          => $args->{id},
            api_key         => $key_data->[CLIENT_api_key],
            trained_backend => 1,
        });
    }
}

sub _train_backend # {{{
{
    my SpamSvc::Serotype::Workers::Train $self = shift;
    my $backend_id  = shift;
    my $disposition = shift;
    my $text_ref    = shift;

    my $connector = $self->connector;
    if ($connector->can('user')) {
        $connector->user($backend_id);
    }
    eval {
        if ($disposition == $HAM) {
            $connector->train_ham($$text_ref);
        }
        elsif ($disposition == $SPAM) {
            $connector->train_spam($$text_ref);
        }
    };
    if ($@) {
        carp tstamp . "train_$disposition failed: $@";
    }
} # }}}

1;

# vim: foldmethod=marker
