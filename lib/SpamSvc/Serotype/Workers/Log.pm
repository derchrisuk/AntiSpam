package SpamSvc::Serotype::Workers::Log;

use strict;
use warnings;

use Carp;
use SpamSvc::Connector ':all';
use SpamSvc::Serotype::Log::Meta;
use SpamSvc::Serotype::Util qw/decrypt_from_base64/;
use SpamSvc::Timestamp;
use Storable qw/nfreeze thaw/;
use Time::HiRes;

use base 'SpamSvc::Serotype::GearmanWorker';

use fields (
    'action_ids',   # mapping of actions to db action_ids; only changes when app changes, so can load from db once at startup
    'level_bits',   # numeric log level from one of LOG_* constants below
    'meta',         # metadata translator
);

use constant {
    LOG_NONE           => 0,
    LOG_METADATA       => 1,
    LOG_REQUEST_BODY   => 2,
    LOG_REQUEST_OTHER  => 4,
    LOG_FACTORS        => 8,
};

sub new # {{{
{
    my $class = shift;
    my $ref = ref $class || $class;

    my SpamSvc::Serotype::Workers::Log $self = SpamSvc::Serotype::GearmanWorker->new(@_);
    bless $self, $class;

    my $config = $self->{config};

    $self->{level_bits} = LOG_NONE;
    if ($config->{log}) {
        if ($config->{log} eq 'all') {
            $self->{level_bits} = LOG_METADATA | LOG_REQUEST_BODY | LOG_REQUEST_OTHER | LOG_FACTORS;
        }
        elsif ($config->{log} eq 'none') {
            $self->{level_bits} = LOG_NONE;
        }
        elsif (ref $config->{log} eq 'ARRAY') {
            for my $bit (@{ $config->{log} }) {
                if ($bit eq 'metadata') {
                    $self->{level_bits} |= LOG_METADATA;
                }
                elsif ($bit eq 'body') {
                    $self->{level_bits} |= LOG_REQUEST_BODY;
                }
                elsif ($bit eq 'other') {
                    $self->{level_bits} |= LOG_REQUEST_OTHER;
                }
                elsif ($bit eq 'factors') {
                    $self->{level_bits} |= LOG_FACTORS;
                }
                else {
                    croak tstamp . "unknown log bit $bit";
                }
            }
        }
        else {
            croak tstamp . "unknown log level $config->{log}";
        }
    }

    $self->{meta} = SpamSvc::Serotype::Log::Meta->new($config);

    $self->register_accounted_method(serotype_log_access => \&_log_access);
    $self->register_accounted_method(serotype_update_log => \&_update_log);

    $self->_prepare_statement_handles('client');
    $self->_prepare_statement_handles('log') if $self->{level_bits};

    return $self;
} # }}}

sub _log_access # {{{
{
    my SpamSvc::Serotype::Workers::Log $self = shift;
    my $job = shift;
    my $arg = $job->arg;

    my $args = thaw($arg);

    my $id = $args->{client_dim_id};

    # update statistics; try not to touch anything returned by fetch_key_data since that requires invalidating memcache
    my $fetch_key_data_invalid = 0;

    $self->_exec_query(qw/ client update_contact_time /, $id);

    my $inc_query = 'increment_count_of_' . $args->{action};
    $self->_exec_query(qw/ client /, $inc_query, $id)
        if exists $self->{dbs}{client}{handles}{$inc_query};

    if ($args->{key_ip_changed} && defined $args->{ip}) {
        $self->_exec_query(qw/ client update_contact_ip /, $args->{ip}, $id);
        $fetch_key_data_invalid = 1;
    }

    if ($self->{memcache} && $fetch_key_data_invalid) {
        $self->{memcache}->delete("serotype:keydata:$args->{api_key}");
    }

    # log to DB
    if (my $level = $self->{level_bits}) {
        if (!$self->{action_ids}) {
            my $res = $self->_exec_query(qw/ log get_action_ids /, sub {
                my $sth = shift;
                $sth->execute();
                return $sth->fetchall_arrayref({});
            });
            $self->{action_ids}{ $_->{action} } = $_->{action_dim_id} for @$res;
        }

        # frequently repeated things (action, ip, apikey, date) are stored in separate tables and each log row just stores an id pointer into those tables. here fetch those pointers from local/memcache or the db

        my $action_id        = $self->{action_ids}{$args->{action}};

        my $api_key_dim_id   = $self->_get_id_from_cache_or_db_with_insert($self->{memcache}, 'log',
            'get_api_key_id', 'insert_api_key_id', 'key',   $args->{api_key});

        my $ip_dim_id        = $self->_get_id_from_cache_or_db_with_insert($self->{memcache}, 'log',
            'get_ip_id',      'insert_ip_id',      'ip',    $args->{ip});

        my $user_ip_dim_id   = $self->_get_id_from_cache_or_db_with_insert($self->{memcache}, 'log',
            'get_ip_id',      'insert_ip_id',      'ip',    $args->{params}{user_ip} || 'unknown');

        my $worker_dim_id    = $self->_get_id_from_cache_or_db_with_insert($self->{local_cache}, 'log',
            'get_worker_id',  'insert_worker_id',  'ident', $self->{ident});

        my $type_dim_id      = $self->_get_id_from_cache_or_db_with_insert($self->{local_cache}, 'log',
            'get_type_id',    'insert_type_id',    'type',  $args->{params}{comment_type} || 'comment');

        my ($date_id, $date) = $self->_get_date_id($self->{local_cache}, $args->{start});
        $date =~ tr/-/_/;

        if (!defined $self->{current_date} || $date ne $self->{current_date}) {
            $self->{current_date} = $date;
            # invalidate all log statement handles so they're rebuilt with new date
            $self->_prepare_statement_handles('log');
        }

        if (!($level & LOG_REQUEST_OTHER)) {
            if ($level == LOG_REQUEST_BODY) {
                # unusual to want only body, but ok
                $args->{params} = { comment_content=>$args->{params}{comment_content} };
            }
            else {
                # nothing at all from request is stored
                delete $args->{params};
            }
        }

        if (!($level & LOG_REQUEST_BODY)) {
            # log some request data, but minus body content
            delete $args->{params}{comment_content};
        }

        my $param_dim_id = undef;
        if ($args->{params}) {
            # pack the parameters and grab the autoinc id
            $self->_exec_query(qw/ log insert_params /,
                Compress::Zlib::compress(nfreeze($args->{params}))
            );

            $param_dim_id = $self->_last_insert_id();

            if (!$param_dim_id) {
                warn tstamp . "failed to get param_dim_id";
                $param_dim_id = undef;
            }
        }

        my $factors_dim_id = undef;
        if ($args->{factors} && ($level & LOG_FACTORS)) {
            # pack the parameters and grab the autoinc id
            $self->_exec_query(qw/ log insert_factors /,
                Compress::Zlib::compress(nfreeze($args->{factors}))
            );

            $factors_dim_id = $self->_last_insert_id();

            if (!$factors_dim_id) {
                warn tstamp . "failed to get factors_dim_id";
                $factors_dim_id = undef;
            }
        }

        $self->_exec_query(qw/ log log_request /,
            $args->{id},
            $action_id,
            $api_key_dim_id,
            $ip_dim_id,
            $user_ip_dim_id,
            $date_id,
            $worker_dim_id,
            $level,
            $type_dim_id,
            $param_dim_id,
            $factors_dim_id,
            $args->{success},
            $args->{rating},
            $args->{confidence},
            $args->{error},
            int(1000*$args->{start}),
            int(1000*$args->{end}),
        );

        $self->_exec_query(qw/ log update_id_date_map /, $args->{id}, $date_id);
    }

    # ignoring $args->{success} for now since error is set on interesting failures
    if (exists $args->{error}) {
        warn tstamp . "error in call to $args->{action}: $args->{error}";
    }

    return 1;
} # }}}

sub _update_log # {{{
{
    my SpamSvc::Serotype::Workers::Log $self = shift;
    my $job = shift;
    my $arg = $job->arg;

    my $args = thaw($arg);

    my %params = map { lc $_ => $args->{params}{$_} } keys %{ $args->{params} };

    my $id = delete $args->{raw_id}; # other workers (eg Train) send original ID via {raw_id} arg
    if (!$id) {
        # but clients send encrypted id as a param
        my $crypt_id = $params{'x-spam-requestid'};

        if (!defined $crypt_id) {
            warn tstamp . "missing X-Spam-RequestID";
            return;
        }

        $id = decrypt_from_base64($self->crypto_key, $crypt_id);

        if ($id !~ /^\d+$/) {
            warn tstamp . "reqid $crypt_id has non-numeric decrypt"
                unless $self->{debug_bits}{ignore_bad_reqid};
            return;
        }
    }

    if (exists $args->{trained_backend}) {
        # TODO this query should use the date of the table that the log job
        # used, not today. as is there's a race at the midnight flip where Log
        # can write to yesterday's log, then this update will fail since the id
        # isn't in today's table.
        $self->_exec_query(log => 'update_trained_backend', $args->{trained_backend}, $id);
    }

    # find which log table this is in
    my ($date) = $self->_exec_query(qw/ log get_date_by_id /, sub {
        my $sth = shift;
        $sth->execute($id);
        return $sth->fetchrow_array();
    });

    if (!$date) {
        warn tstamp . "got notification for unmapped id $id"
            unless $self->{debug_bits}{ignore_bad_reqid};
        return;
    }

    # validate key/id combo
    my ($api_key) = $self->_exec_dated_query(qw/ log get_api_key_by_id /, $date, sub {
        my $sth = shift;
        $sth->execute($id);
        return $sth->fetchrow_array();
    });

    if (!$api_key) {
        warn tstamp . "mapped id $id wasn't found in request_log_$date"
            unless $self->{debug_bits}{ignore_bad_reqid};
        return;
    }

    if ($api_key ne $args->{api_key}) {
        warn tstamp . "api_key mismatch updating $id ($args->{id})";
        return;
    }

    my %prop_types = (
        captcha_passed  => 'boolean',
        system_action   => 'enum',
        user_action     => 'enum',
    );

    for my $prop (keys %prop_types) {
        if (my $user_value = $params{$prop}) {
            my $type = $prop_types{$prop};

            my $db_value;
            ($db_value, $type) = $self->{meta}->user_value_to_db_pair($prop, $user_value);
            unless (defined $db_value) {
                warn tstamp . sprintf "bad value $user_value for prop $prop"
                    if $self->{debug_bits}{notify};
                next;
            }

            # TODO create ext_meta_* table if doesn't exist

            if ($self->{debug_bits}{notify}) {
                warn tstamp . "setting prop $prop:$db_value on $id\n";
            }

            my $index = $self->{meta}->prop_str2int($prop);
            croak "unconfigured index for prop $prop" unless defined $index;

            $self->_exec_dated_query(
                'log',
                'set_meta_' . $type,
                $date,
                $id,
                $index,
                $db_value
            );
        }
    }

    return 1;
} # }}}

sub _get_id_from_cache_or_db # {{{
# attempt to grab the dim_id of a id<->value table, given the value.
# effecitvely grabs the first value from the first row of a query result set, attempting to read first from memcache and writing to memcache after falling back to db
{
    my SpamSvc::Serotype::Workers::Log $self = shift;
    my $cache   = shift;
    my $db      = shift; # database to use
    my $query   = shift; # fetch query name
    my $ns      = shift; # namespace for memcache key
    my $value   = shift; # value to pass to query

    my $key     = "serotype:log:$ns:$value";

    if ($cache) {
        my $ret = $cache->get($key);
        if ($self->{debug_bits}{cache}) {
            printf STDERR '%8s ', $cache eq $self->{local_cache} ? 'local' : 'memcache';
            printf STDERR "%s\n",   defined $ret ? "hit  $key = $ret" : "miss $key";
        }
        return $ret if defined $ret;
    }
    my $id = $self->_exec_query($db, $query, sub {
        my $sth = shift;
        $sth->execute($value);
        my $ref = $sth->fetchrow_arrayref();
        if (defined $ref && @$ref) {
            my $val = $ref->[0];
            if ($cache) {
                if ($self->{debug_bits}{cache}) {
                    printf STDERR '%8s ', $cache eq $self->{local_cache} ? 'local' : 'memcache';
                    printf STDERR "set  %s = %s\n", $key, $val;
                }
                $cache->set($key, $val);
            }
            return $val;
        }
        else {
            return undef;
        }
    });
    return $id;
} # }}}

sub _get_id_from_cache_or_db_with_insert # {{{
# attempt to _get_id_from_cache_or_db, and if it fails, insert the value, then repeat get_id
{
    my SpamSvc::Serotype::Workers::Log $self = shift;
    my $cache   = shift;
    my $db      = shift; # database to use
    my $fetch   = shift; # fetch query name
    my $insert  = shift; # insert query name
    my $ns      = shift; # namespace for cache key
    my $value   = shift; # value to pass to query

    return undef unless defined $value;

    my $id = $self->_get_id_from_cache_or_db($cache, $db, $fetch, $ns, $value);

    return $id if defined $id;

    # not yet there, insert it
    # XXX do lookup+insert in sproc
    $self->_exec_query($db, $insert, $value);

    # should be there now, redo fetch (which will stash it in cache)
    $id = $self->_get_id_from_cache_or_db($cache, $db, $fetch, $ns, $value);

    if (!defined $id) {
        warn tstamp . "id for $db:$ns:$value is still NULL after insert";
    }

    return $id;
} # }}}

sub _get_date_id # {{{
{
    my SpamSvc::Serotype::Workers::Log $self = shift;
    my $cache = shift;
    my $time = shift;
    my @l = localtime $time;
    $l[5] += 1900; # year
    $l[4]++; # month
    my $date = sprintf "%04d-%02d-%02d", @l[5, 4, 3];

    my $id = $self->_get_id_from_cache_or_db($cache, 'log', 'get_date_id', 'date', $date);
    return wantarray ? ($id, $date) : $id;
} # }}}

1;

# vim: foldmethod=marker
