package SpamSvc::Serotype::Workers::HealthCheck;

use strict;
use warnings;

use Storable qw/nfreeze thaw/;
use Sys::Load qw/getload uptime/;
use Sys::MemInfo qw/freemem totalmem freeswap totalswap/;

use base 'SpamSvc::Serotype::GearmanWorker';

use fields (
    'failures', # hash of opaque keys to number of failures since last call to _health_check
);

sub new {
    my $class = shift;
    my $ref = ref $class || $class;

    my SpamSvc::Serotype::Workers::HealthCheck $self = SpamSvc::Serotype::GearmanWorker->new(@_);
    bless $self, $class;

    $self->{failures} = {};

    $self->register_accounted_method(serotype_health_check     => \&_health_check);
    $self->register_accounted_method(serotype_log_late_failure => \&_log_late_failure);

    return $self;
}

sub _health_check {
    my SpamSvc::Serotype::Workers::HealthCheck $self = shift;
    my $job = shift;

    my $args = thaw($job->arg);

    my @load = getload();
    my $uptime = uptime();

    my %failures;
    while (my ($type, $count) = each %{ $self->{failures} }) {
        $failures{"failure_$type"} = $count;
    }
    $self->{failures} = {};

    return nfreeze {
        sys_uptime  => $uptime,
        sys_load1   => $load[0],
        sys_load5   => $load[1],
        sys_load15  => $load[2],
        freemem     => freemem,
        totalmem    => totalmem,
        freeswap    => freeswap,
        totalswap   => totalswap,
        %failures,
    };
}

sub _log_late_failure {
    my SpamSvc::Serotype::Workers::HealthCheck $self = shift;
    my $job = shift;

    my $args = thaw($job->arg);

    # for now just count them
    $self->{failures}{ $args->{type} }++;

    return;
}

1;
