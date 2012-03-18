package SpamSvc::Serotype::GearmanWorker;

# this module contains code shared between serotype's various gearman workers

# {{{ imports
use strict;
use warnings;

use Cache::Memcached::GetParserXS;
use Cache::Memcached;
use Cache::Memory;
use Carp;
use Compress::Zlib ();
use Data::Dumper;
use Data::YUID::Client;
use Data::YUID::Generator;
use DBI;
use Digest::MD5;
use File::Temp;
use IO::Socket::INET;
use Gearman::Client;
use Gearman::Worker;
use List::Util qw/min max/;
use POSIX 'strftime';
use Serotype '$VERSION';
use SpamSvc::Connector ':all';
use SpamSvc::Connector::DSPAM::Client;
use SpamSvc::Serotype::Config;
use SpamSvc::Serotype::KeyPlugin;
use SpamSvc::Serotype::Util 'mtime';
use SpamSvc::Timestamp;
use Storable qw/nfreeze thaw/;
use Time::HiRes;
use URI::Find;
# }}}

# {{{ class/option declarations
use base 'Gearman::Worker';

use fields (
    'connector',    # backend connector object; use connector() to access
    'dbs',          # database connections
    'memcache',     # memcache client
    'config',       # hash of config options
    'slot',         # worker slot id
    'hostname',     # hostname of the executing host
    'ident',        # string identifying this worker
    'gearman',      # gearman client object for injecting post-query jobs
    'yuid',         # yuid client
    'current_date', # 200x_xx_xx format date of last log event
    'jobs_done',    # number of gearman jobs this worker has handled
    'debug_bits',   # individual debug behaviors
    'local_cache',  # small, fast Cache::Memory object for frequently queried tables with very fews rows
    'reload',       # state for checking if disk configuration has changed
);
# }}}

sub new # {{{
{
    my $class   = shift;
    my $ref     = ref $class || $class;
    my $slot    = shift;
    my $params  = shift;

    my ($config, $config_files) = SpamSvc::Serotype::Config::load_config($params->{config});

    my $gearman_args = $config->{gearman_args} || {};

    my SpamSvc::Serotype::GearmanWorker $self = Gearman::Worker->new(%$gearman_args);
    bless $self, $class;

    # all workers share a single config; subclass workers grab from self->{config}
    $self->{config} = $config;

    $self->{reload}{mtimes} = { map { $_ => mtime($_) } @$config_files };
    $self->{reload}{check_period} = 50;
    $self->{reload}{check_remaining} = $self->{reload}{check_period};

    $self->{config}{tune_limit} ||= 0;

    $self->{slot} = $slot;

    if (defined $config->{debug} && ref $config->{debug} eq 'ARRAY') {
        for my $bit (@{ $config->{debug} }) {
            $self->{debug_bits}{$bit} = 1;
        }
    }
    else {
        $self->{debug_bits} = {};
    }

    my $backend = lc $config->{backend};
    my $backend_args = $config->{backend_args} || {};

    my $connector_class = undef;
    if ($backend eq 'dspamc') {
        $connector_class = 'SpamSvc::Connector::DSPAM::Client';
    }
    else {
        croak tstamp . "unknown backend type $config->{backend}";
    }
    $self->connector($connector_class->new(%$backend_args));

    croak tstamp . 'no global_username set' unless defined $self->{config}{global_username};

    my @l = localtime time;
    $self->{current_date} = sprintf "%04d_%02d_%02d", $l[5]+1900, $l[4]+1, $l[3];

    die tstamp . "no serotype gearman servers specified" unless $config->{gearman_servers}{serotype};
    $self->{gearman} = Gearman::Client->new;
    $self->{gearman}->job_servers($config->{gearman_servers}{serotype});

    $self->{jobs_done} = 0;

    chomp(my $hostname_bin = `which hostname`);
    chomp(my $hostname = (-x $hostname_bin && `$hostname_bin`) || $ENV{HOST} || $ENV{HOSTNAME} || 'unknown');
    $self->{hostname} = $hostname;
    $self->{ident} = "Serotype-$VERSION:$hostname:$self->{slot}";

    if ($config->{memcached_servers}) {
        $self->{memcache} = Cache::Memcached->new({'servers' => $config->{memcached_servers}});
    }
    else {
        $self->{memcache} = undef;
    }

    if ($config->{yuid_servers}) {
        $self->{yuid} = Data::YUID::Client->new(servers => $config->{yuid_servers});
    }
    else {
        $self->{yuid} = Data::YUID::Generator->new;
    }

    $self->{local_cache} = Cache::Memory->new(size_limit => ($config->{local_cache_size} || 100_000));

    return $self;
} # }}}

sub load_config # {{{
{
    return SpamSvc::Serotype::Config::load_config(@_);
} # }}}

sub post_work # {{{
{
    my SpamSvc::Serotype::GearmanWorker $self = shift;

    exit 0 if defined $self->{config}{max_jobs} && $self->{jobs_done} >= $self->{config}{max_jobs};

    # reload if config has changed
    if (--$self->{reload}{check_remaining} <= 0) {
        while (my ($file, $mtime) = each %{ $self->{reload}{mtimes} }) {
            if (mtime($file) > $mtime) {
                warn tstamp . "config file $file changed, exiting\n";
                exit 0;
            }
        }
        $self->{reload}{check_remaining} = $self->{reload}{check_period};
    }
} # }}}

sub connector # {{{
{
    my SpamSvc::Serotype::GearmanWorker $self = shift;
    my $connector = shift;
    if ($connector) {
        $self->{connector} = $connector;
    }
    return $self->{connector};
} # }}}

sub register_accounted_method # {{{
{
    # call Gearman::Worker->register_function wrapped with an accounting stub
    my SpamSvc::Serotype::GearmanWorker $self = shift;
    my $name   = shift;
    my $method = shift;
    $self->register_function($name => sub {
        $self->_log_worker_entry($name, $$, @_);
        $self->{jobs_done}++;
        return $self->$method(@_);
    });
} # }}}

# {{{ constants

# for retrying sql execution
my $min_backoff = 1;
my $max_backoff = 10;
my $sql_retries = 10;

# }}}

# symmetric key for de/encrypting the request ID given to clients
my $_crypto_key;
sub crypto_key # {{{
{
    my SpamSvc::Serotype::GearmanWorker $self = shift;
    return $_crypto_key ||= pack 'H*', $self->{config}{id_crypto_key};
} # }}}

sub submit_task # {{{
{
    my SpamSvc::Serotype::GearmanWorker $self = shift;
    my $func = shift;
    my $args = shift;
    $self->{gearman}->dispatch_background($func, \nfreeze($args), {
        retry_count => 3,
        on_retry => sub {
            warn tstamp . "retry: $func($args->{id})\n";
        },
        on_fail => sub {
            warn tstamp . "fail:  $func($args->{id})\n";
        },
    });
} # }}}

sub _connect_to_db # {{{
{
    my SpamSvc::Serotype::GearmanWorker $self = shift;
    my $db = shift;

    my $conf = $self->{config}{databases}{$db};

    my $dsn = "DBI:mysql:database=$conf->{db};host=$conf->{host};port=$conf->{port}";
    $dsn .= ';mysql_server_prepare=1' if $conf->{server_prepare};
    return $self->{dbs}{$db}{dbh}
        = DBI->connect($dsn, $conf->{user}, $conf->{password}, {RaiseError => 1});
} # }}}

sub _prepare_statement_handles # {{{
{
    my SpamSvc::Serotype::GearmanWorker $self = shift;
    my $db = shift;

    my $backoff = $min_backoff;
    REDO: {
        my $ok = 1;
        eval {
            my $db_sql = $self->{config}{sql}{$db};

            my $dbh = $self->_connect_to_db($db);

            for my $label (sort keys %$db_sql) {
                my $sql = $db_sql->{$label};

                # can't prepare these since table name is dynamic and driver is
                # allowed to throw an error if the table doesn't exist
                next if $sql =~ /GIVENDATE/;

                # prepare later when date is known (shouldn't happen)
                next if $sql =~ /CURRENTDATE/ && !defined $self->{current_date};

                $sql =~ s/CURRENTDATE/$self->{current_date}/g;

                # server-side stmt prep fails if table doesn't exist, so need
                # to exec CREATE TABLE first. _init_* are first in sort
                # order so we'll see these first and get a chance to
                # execute before later prep
                if ($label =~ /^_init/) {
                    $dbh->do($sql);
                }
                else {
                    my $sth = $self->{dbs}{$db}{handles}{$label} = $dbh->prepare($sql);
                    $ok = 0 unless $sth;
                }
            }
        };
        if ($@ || !$ok) {
            Carp::cluck tstamp . $@ if $self->{debug_bits}{database};
            sleep $backoff;
            $backoff = min(1.5*$backoff, $max_backoff);
            redo REDO;
        }
        else {
            $backoff = $min_backoff;
        }
    }
} # }}}

sub _dispatch_query_result # {{{
{
    my $sth = shift;
    my $action = shift;
    my $ret;
    if ($action->[0] && ref $action->[0] eq 'CODE') {
        my $sub = shift @$action;
        $ret = $sub->($sth, @$action);
    }
    else {
        my $ret = $sth->execute(@$action);
    }
    $sth->finish;
    return $ret;
} # }}}

sub _exec_query # {{{
# execute a named, pre-prepared sql query with retry on exception
{
    my SpamSvc::Serotype::GearmanWorker $self = shift;
    my $db     = shift; # type connecting to (a toplevel key in %$sql)
    my $name   = shift; # query name, sub-key in %$sql
    my @action = @_;    # coderef which is passed $sth and args, or args to pass to $sth->execute

    for (my $tries = 0; $tries < $sql_retries; $tries++) {
        my $ret = eval {
            my $sth = $self->{dbs}{$db}{handles}{$name};
            confess "tried to exec unprepared query $db/$name" unless $sth;
            return _dispatch_query_result($sth, \@action);
        };
        if ($@) {
            carp tstamp . "database error in query $db/$name: $@";
            $self->_prepare_statement_handles($db);
        }
        else {
            return $ret;
        }
    }
    $self->_log_late_failure('_exec_query', __FILE__, __LINE__);
    carp tstamp . "giving up on $db/$name";
} # }}}

sub _exec_dated_query # {{{
# execute a named, unprepared sql query on dated table with retry on exception
{
    my SpamSvc::Serotype::GearmanWorker $self = shift;
    my $db     = shift; # type connecting to (a toplevel key in %$sql)
    my $name   = shift; # query name, sub-key in %$sql
    my $date   = shift; # YYYY_MM_DD format
    my @action = @_;    # coderef which is passed $sth and args, or args to pass to $sth->execute

    $date =~ tr/-/_/;

    my $sql = $self->{config}{sql}{$db}{$name};
    $sql =~ s/GIVENDATE/$date/g;

    for (my $tries = 0; $tries < $sql_retries; $tries++) {

        my $ret = eval {
            my $sth = $self->_connect_to_db($db)->prepare($sql);
            confess "failed to prepare query $db/$name" unless $sth;
            return _dispatch_query_result($sth, \@action);
        };
        if ($@) {
            carp tstamp . "database error in query $db/$name: $@";
        }
        else {
            return $ret;
        }
    }
    $self->_log_late_failure('_exec_dated_query', __FILE__, __LINE__);
    carp tstamp . "giving up on $db/$name";
} # }}}

sub _exec_sql # {{{
# execute a raw sql query with retry & reconnect on exception
{
    my SpamSvc::Serotype::GearmanWorker $self = shift;
    my $db     = shift; # type connecting to (a toplevel key in %$sql)
    my $sql    = shift; # query string
    my @action = @_;    # coderef which is passed $sth and args, or args to pass to $sth->execute

    for (my $tries = 0; $tries < $sql_retries; $tries++) {
        my $ret = eval {
            my $sth = $self->_connect_to_db($db)->prepare($sql);
            confess "failed to prepare query $db/$sql" unless $sth;
            return _dispatch_query_result($sth, \@action);
        };
        if ($@) {
            carp tstamp . "database error in query $db/$sql: $@";
        }
        else {
            return $ret;
        }
    }
    $self->_log_late_failure('_exec_sql', __FILE__, __LINE__);
    carp tstamp . "giving up on $db/$sql";
} # }}}

sub _last_insert_id # {{{
{
    my SpamSvc::Serotype::GearmanWorker $self = shift;
    my ($id) = $self->_exec_query(qw/ log get_last_insert_id /, sub {
        my $sth = shift;
        $sth->execute;
        return $sth->fetchrow_array();
    });
    return $id;
} # }}}

my $syslog_sock;
sub _syslog # {{{
{
    my $message = shift;

    $syslog_sock ||= IO::Socket::INET->new(
        Proto    => 'udp',
        PeerAddr => 'localhost',
        PeerPort => 514,
        Blocking => 0,
    );

    return unless $syslog_sock;

    my $facility = 20; # local4
    my $severity = 7; # debug

    # based on http://www.faqs.org/rfcs/rfc3164.html
    my $packet = sprintf "<%d>%s %s %s[%d]: %s",
        ( ($facility << 3) | $severity ), # RFC3164: 4.1.1 PRI Part
        strftime('%b %d %H:%M:%S', localtime time),
        'localhost',
        'Serotype',
        $$,
        tstamp . $message;

    $syslog_sock->write($packet);
} # }}}

sub _log_worker_entry # {{{
{
    my SpamSvc::Serotype::GearmanWorker $self = shift;
    my $worker   = shift;
    my $pid      = shift;
    my $job      = shift;

    return unless $self->{debug_bits}{log_worker_entry};

    _syslog("$pid entered $worker");

    my $unpacked = eval {
        thaw $job->arg;
    };

    my $id = 'unknown';
    if (defined $unpacked && ref $unpacked eq 'ARRAY') {
        $id = $unpacked->[4];
    }

    _syslog("$pid entered $worker with id=$id");

} # }}}

sub _log_late_failure # {{{
{
    my SpamSvc::Serotype::GearmanWorker $self = shift;
    my ($type, $file, $line) = @_;
    $self->submit_task(serotype_log_late_failure => {
        type    => $type,
        source  => "$file:$line",
    });
} # }}}

1;

# vim: foldmethod=marker
