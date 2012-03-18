package Perlbal::Plugin::SerotypeProxy;

# {{{ imports
use strict;
use warnings;

use Carp;
use CGI::Deurl::XS 0.03;
use Data::Dumper;
use Gearman::WorkerSpawner;
use List::Util qw/min max sum/;
use POSIX ":sys_wait_h";
use Perlbal;
use Perlbal::ClientProxy;
use Perlbal::HTTPHeaders;
use Serotype qw/ $VERSION $DATE $REVISION /;
use SpamSvc::Serotype::GearmanWorker;
use SpamSvc::Timestamp;
use Storable qw/nfreeze thaw/;
use Time::HiRes;
use YAML::Syck 'Dump', 'LoadFile';
# }}}

# {{{ constants
use constant HANDLE_REQUEST => 0;
use constant IGNORE_REQUEST => 1;
use constant MAX_CONTENT_LENGTH => 32_000;
# }}}

sub load # {{{
{
    my $class = shift;

    Perlbal::Service::add_tunable(
        worker_config => {
            check_role => '*',
            des => "path to Serotype gearman worker config file",
        },
    );
    Perlbal::Service::add_tunable(
        history_length => {
            check_role => '*',
            check_type => 'int',
            des => "number of events to keep in memory for computing status",
            default => 1000,
        },
    );
    Perlbal::Service::add_tunable(
        gearmand => {
            check_role => '*',
            des => "comma separated list of gearmands",
            default => 'localhost',
        },
    );
    Perlbal::Service::add_tunable(
        debug => {
            check_role => '*',
            check_type => 'int',
            des => "debugging level",
            default => '0',
        },
    );

    return 1;
}
# }}}

our $STARTUP_TIME = Time::HiRes::time;

my $last_fatal;

sub register # {{{
{
    my ($class, $svc) = @_;

    my $cfg = $svc->{extra_config} ||= {};

    Perlbal::log(info => 'Registering ' . __PACKAGE__);

    die tstamp . "worker_config not specified\n" unless exists $cfg->{worker_config};

    my $worker_config = SpamSvc::Serotype::GearmanWorker::load_config($cfg->{worker_config});

    my $spawner = Gearman::WorkerSpawner->new(gearmand => $cfg->{gearmand});

    for my $type (qw/ Query Train Log HealthCheck /) {
        die tstamp . "no worker count provided for type $type\n" unless $worker_config->{workers}{$type};
        $spawner->add_worker(
            class       => "SpamSvc::Serotype::Workers::$type",
            num_workers => $worker_config->{workers}{$type},
            worker_args => {config => $cfg->{worker_config}},
        );
    }

    # {{{ periodically run health check
    my $health = {};
    _run_periodically($worker_config->{health_check_period} || 60, sub {
        $spawner->add_task(Gearman::Task->new(
            'serotype_health_check',
            \nfreeze({}),
            {
                retry_count => 3,
                timeout     => 1,
                on_fail     => sub {
                    my $reason = shift;
                    warn "health check failed: $reason";
                },
                on_complete => sub {
                    my $ref = shift;
                    $health = thaw $$ref;
                },
            },
        ));
    }); # }}}

    $spawner->wait_until_all_ready;

    warn tstamp . "all workers started\n";

    my @history;
    my $stats = undef;
    my $history_updater = sub {
        my $event = shift;
        $last_fatal = time if !defined $event;
        $stats = undef; # invalidate stats cache
        push @history, $event;
        shift @history if @history > $cfg->{history_length};
    };

    chomp(my $hostname_bin = `which hostname`);
    chomp(my $hostname = (-x $hostname_bin && `$hostname_bin`) || $ENV{HOST} || $ENV{HOSTNAME} || 'unknown');
    my $ident = "$hostname:$$";

    my %legal_uris = map {$_ => 1} qw{
        /1.1/verify-key
        /1.1/comment-check
        /1.1/submit-spam
        /1.1/submit-ham
        /1.1/notify
        /status
    };

    $svc->register_hook('GearmanProxy', 'start_http_request' => sub {
        my Perlbal::ClientProxy $cp = shift;

        warn tstamp . "in start_http_request handler\n" if $cfg->{debug} >= 2;

        return IGNORE_REQUEST unless $cp;

        my Perlbal::HTTPHeaders $headers = $cp->{req_headers};

        my $uri = $headers->request_uri();

        # uri is present and allowed?
        unless (defined $uri) {
            $cp->send_response(400, "Server error.\n");
            warn tstamp . "no uri header\n";
            return IGNORE_REQUEST;
        }
        unless (exists $legal_uris{$uri}) {
            # don't know you
            $cp->send_response(404, "Not found.\n");
            warn tstamp . "illegal uri: $uri\n";
            return IGNORE_REQUEST;
        }

        my $ip = $cp->observed_ip_string() || $cp->peer_ip_string();
        unless (defined $ip) {
            $cp->send_response(500, "Server error.\n");
            warn tstamp . "no ip\n";
            return IGNORE_REQUEST;
        }

        if ($uri eq '/status') {
            $stats = _update_stats(\@history) unless defined $stats;
            $cp->send_response(200, _status_report({%$stats, %$health}, $ident));
            return IGNORE_REQUEST;
        }

        if ($headers->request_method ne 'POST') {
            # not a getter
            $cp->send_response(404, "Only POST requests supported\n");
            return IGNORE_REQUEST;
        }

        return HANDLE_REQUEST;
    });

    $svc->register_hook('GearmanProxy', 'proxy_read_request' => sub {
        my Perlbal::ClientProxy $cp = shift;
        return IGNORE_REQUEST unless $cp;

        warn tstamp . "in proxy_read_request handler\n" if $cfg->{debug} >= 2;

        my Perlbal::HTTPHeaders $headers = $cp->{req_headers};

        my $ip = $cp->observed_ip_string() || $cp->peer_ip_string();
        unless (defined $ip) {
            $cp->send_response(500, "Server error.\n");
            warn tstamp . "no ip\n";
            return IGNORE_REQUEST;
        }

        if ($cp->{request_body_length} > MAX_CONTENT_LENGTH) {
            $cp->send_response(400, "Content too long.\n");
            warn tstamp . "MAX_CONTENT_LENGTH exceeded by $ip\n";
            return IGNORE_REQUEST;
        }

        # this is implicitly required by the akismet spec
        if ($headers->header('content-type') !~ m{^application/x-www-form-urlencoded}i) {
            $cp->send_response(400, "Illegal content-type.\n");
            warn tstamp . 'illegal content-type ' . $headers->header('content-type') . " from $ip\n";
            return IGNORE_REQUEST;
        }

        my $uri = $headers->request_uri();

        my $data = join '', map {$$_} @{ $cp->{read_buf} };
        my $params = CGI::Deurl::XS::parse_query_string($data);

        my $action;
        my $api_key;
        if (
            $uri eq '/1.1/comment-check' ||
            $uri eq '/1.1/submit-spam' ||
            $uri eq '/1.1/submit-ham' ||
            $uri eq '/1.1/notify'
        ) {
            $action = substr $uri, 5; # strip /1.1/

            if (defined $params->{key}) {
                $api_key = delete $params->{key};
            }
            elsif (defined $headers->header('api-key')) {
                $api_key = $headers->header('api-key');
            }
            elsif (defined $headers->header('host') && $headers->header('host') =~ /^([^.]+)\./) {
                $api_key = $1;
            }
            else {
                warn tstamp . "couldn't get api key from host\n";
                $cp->send_response(400, "useragent didn't provide a valid host header\n");
                return IGNORE_REQUEST;
            }
        }
        elsif ($uri eq '/1.1/verify-key') {
            $action = 'verify-key';
            $api_key = delete $params->{key};
        }
        else {
            # that's weird, these should be caught by start_http_request
            $cp->send_response(404, "Not found.\n");
            warn tstamp . "unhandled uri $uri\n";
            return IGNORE_REQUEST;
        }

        my $id = rand;
        my @args = ($action, $ip, $api_key, $params, $id);

        my $query_task = Gearman::Task->new(
            'serotype_query',
            \nfreeze(\@args),
            {
                retry_count => 3,
                timeout     => 1,
                on_retry    => sub {
                    my $reason = shift;
                    warn tstamp . "retry: $action $ip $api_key $id ($reason)\n";
                },
                on_fail     => sub {
                    my $reason = shift;
                    $history_updater->(undef);
                    $cp->send_response(503, 'Temporary Failure');

                    warn tstamp . "fail:  $action $ip $api_key $id ($reason)\n";
                },
                on_complete => sub {
                    _on_query_complete($_[0], $history_updater, $cp);
                },
            },
        );
        $spawner->add_task($query_task);

        # tell perlbal to ignore the request for now. when $backend_task
        # completes, _on_complete fires and picks up with the $cp
        return IGNORE_REQUEST;
    });

    warn tstamp . "serotype proxy running\n";
}
# }}}

use constant ARG_code     => 0;
use constant ARG_body     => 1;
use constant ARG_headers  => 2;
use constant ARG_log_task => 3;

sub _on_query_complete # {{{
{
    my $data            = shift;
    my $history_updater = shift;
    my $cp              = shift;

    my $args;
    eval {
        die tstamp . "no data" unless $data && $$data;
        $args = thaw($$data);
        die tstamp . "no args" unless $args;
        die tstamp . "args is not an array" unless ref($args) eq 'ARRAY';
    };
    if ($@) {
        $cp->send_response(500, 'Internal Server Error');
        return;
    }

    $history_updater->($args->[ARG_log_task]);

    my $res = $cp->{res_headers} = Perlbal::HTTPHeaders->new_response($args->[ARG_code]);
    $res->header('Content-Type', 'text/html;charset=utf-8');
    $res->header('Content-Length', length($args->[ARG_body]));
    if (defined $args->[ARG_headers] && ref($args->[ARG_headers]) eq 'HASH') {
        while (my ($key, $value) = each %{ $args->[ARG_headers] }) {
            $res->header($key, $value);
        }
    }
    $cp->setup_keepalive($res);
    $cp->state('xfer_resp');
    $cp->tcp_cork(1); # cork writes to self
    $cp->write($res->to_string_ref);
    $cp->write(sub { $cp->tcp_cork(0); }); # immediately push headers
    $cp->write(\$args->[ARG_body]);
    $cp->write(sub { $cp->http_response_sent; });
}
# }}}

sub unregister # {{{
{
    my ($class, $svc) = @_;

    $svc->unregister_hooks('GearmanProxy');
    return 1;
}
# }}}

sub median # {{{
{
    if (@_ % 2 == 0) {
        return ($_[@_/2 - 1] + $_[@_/2]) / 2;
    }
    else {
        return $_[int(@_/2)];
    }
} # }}}

sub _update_stats # {{{
{
    my $history = shift;

    my $errors = 0;
    my $events = 0;
    my $fatals = 0;

    my @times;

    my ($early, $late);
    $early = $late = time;
    for my $event (@$history) {
        $events++;

        if (!defined $event) {
            # fatal error
            $fatals++;
            $errors++;
            next;
        }

        unless ($event->{success}) {
            # non-fatal error
            $errors++;
        }

        if (defined $event->{start} && defined $event->{start}) {
            $early = $event->{start} if $event->{start} < $early;
            $late  = $event->{end}   if $event->{end}   > $late;

            push @times, 1000*($event->{end} - $event->{start});
        }
    }
    my $period = $late - $early;

    my $now = Time::HiRes::time;

    my %stats = (
        uptime              => $now - $STARTUP_TIME,
        events              => $events,
        period              => $period,
        fatals              => $fatals,
        errors              => $errors,
        throughput          => $events / ($period||1),
        success_rate        => 100*($events-$errors) / ($events||1),
        scalar @times ? (
            min_elapsed     => min(@times),
            max_elapsed     => max(@times),
            mean_elapsed    => sum(@times) / @times,
            median_elapsed  => median(sort @times),
        ) : (),
    );

    if (defined $last_fatal) {
        $stats{since_fatal} = $now - $last_fatal;
    }

    return \%stats;
}
# }}}

my %status_formats = (
    uptime          => '%.3f',
    events          => '%d',
    period          => '%.3f',
    errors          => '%d',
    fatals          => '%d',
    since_fatal     => '%d',
    throughput      => '%.2f',
    success_rate    => '%.2f',
    min_elapsed     => '%.2f',
    max_elapsed     => '%.2f',
    mean_elapsed    => '%.2f',
    median_elapsed  => '%.2f',
    sys_uptime      => '%d',
    sys_load1       => '%.2f',
    sys_load5       => '%.2f',
    sys_load15      => '%.2f',
);

sub _status_report # {{{
{
    my $stats = shift;
    my $ident = shift;
    my $report;

    $report .= "version=$VERSION\n";
    $report .= "revision=$REVISION\n";
    $report .= "built=$DATE\n";
    $report .= "ident=$ident\n";
    $report .= sprintf "now=%f\n", Time::HiRes::time;

    for my $stat (keys %$stats) {
        $status_formats{$stat} ||= '%s';
        $report .= sprintf "%s=$status_formats{$stat}\n", $stat, $stats->{$stat};
    }
    return _html_wrap($report);
} # }}}

sub _html_wrap # {{{
{
    my $text = shift;
    return "<html><body><pre>\n$text</pre></body></html>\n";
} # }}}

use constant ALERT_OK   => 0;
use constant ALERT_WARN => 1;
use constant ALERT_CRIT => 2;

sub _run_periodically # {{{
{
    my $period = shift;
    my $sub    = shift;
    my @args   = @_;

    my $recycler;
    $recycler = sub {
        $sub->(@args);
        Danga::Socket->AddTimer($period, $recycler);
    };
    Danga::Socket->AddTimer(0, $recycler);
} # }}}

1;

# vim: foldmethod=marker
