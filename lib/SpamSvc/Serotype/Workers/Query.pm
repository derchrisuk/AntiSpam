package SpamSvc::Serotype::Workers::Query;

use strict;
use warnings;

use Carp;
use Digest::MD5 'md5_base64';
use LWP::UserAgent;
use LWPx::ParanoidAgent;
use SpamSvc::Connector ':all';
use SpamSvc::FrequencyTracker;
use SpamSvc::Serotype::KeyPlugin;
use SpamSvc::Serotype::Rules;
use SpamSvc::Serotype::Transformer ':all';
use SpamSvc::Serotype::Util qw/encrypt_to_base64/;
use SpamSvc::Serotype::Util::Encode;
use SpamSvc::Serotype::Workers::Client;
use SpamSvc::Timestamp;
use Storable qw/nfreeze thaw/;
use Time::HiRes;

use base 'SpamSvc::Serotype::Workers::Client';

use fields (
    'ua',               # user-agent for fetching trackbacks
    'request_trackers', # for tracking excessive identical input
    'rule_box',         # Rules object
);

sub new # {{{
{
    my $class = shift;
    my $ref = ref $class || $class;

    my SpamSvc::Serotype::Workers::Query $self = SpamSvc::Serotype::Workers::Client->new(@_);
    bless $self, $class;

    $self->register_accounted_method(serotype_query => \&_query);

    if ($self->{config}{trackback}{http_proxy}) {
        # ParanoidAgent lacks proxy support; proxy must take own anti-tarpit measures
        $self->{ua} = LWP::UserAgent->new;
        $self->{ua}->proxy('http', $self->{config}{trackback}{http_proxy});
    }
    else {
        $self->{ua} = LWPx::ParanoidAgent->new;
    }
    $self->{ua}->timeout($self->{config}{trackback}{fetch_timeout});

    for my $object (keys %{ $self->{config}{frequency} }) {
        $self->{request_trackers}{$object} = SpamSvc::FrequencyTracker->new(
            namespace   => $object,
            halflife    => $self->{config}{frequency}{$object}{halflife},
            cache       => $self->{memcache},
        );
    }

    $self->{rule_box} = SpamSvc::Serotype::Rules->new();

    return $self;
} # }}}

# submits any followup jobs, then returns an nfrozen hashref containing an http
# response code, response text, any extra headers, and log task parameters
sub _generate_response # {{{
{
    my SpamSvc::Serotype::Workers::Query $self = shift;
    my $code    = shift;
    my $body    = shift;
    my $headers = shift;
    my $tasks   = shift;
    my %logs    = @_;

    # finalize log task
    my $log_task = $tasks->{serotype_log_access};
    $log_task->{$_} = $logs{$_} for keys %logs;
    $log_task->{end} = Time::HiRes::time;
    if ($log_task->{error}) {
        # anything tagged with an error failed
        $log_task->{success} = 0;
    }
    elsif (!exists $log_task->{success}) {
        # unless overridden, assume 2xx responses were successful
        $log_task->{success} = ($code =~ /^2/) ? 1 : 0;
    }

    while (my ($func, $args) = each %$tasks) {
        $self->submit_task($func, $args);
    }

    my $ret = eval {
        return nfreeze([$code, $body, $headers, $log_task]);
    };
    $@ && carp tstamp . "error: $@";
    return $ret;
} # }}}

sub _query # {{{
{
    my SpamSvc::Serotype::Workers::Query $self = shift;
    my $job = shift;

    my $arg = thaw($job->arg);
    my ($action, $ip, $api_key, $params) = @$arg;

    # generate a unique id for this request
    my $id = $self->{yuid}->get_id();

    # most responses are accompanied by a new gearman log job since we don't want response to block on logging
    my $decoded_params = $params;
    my %log_task = (
        id              => $id,
        worker          => $self->{ident},
        action          => $action,
        api_key         => $api_key,
        client_dim_id   => undef,
        ip              => $ip,
        params          => $decoded_params,
        start           => Time::HiRes::time,
    );
    my %tasks = (
        serotype_log_access => \%log_task,
    );
    my %headers; # any extra HTTP headers to provide to the client

    # give clients a unique ID but make sure they can't guess another ID since yuid is semi-deterministic
    $headers{'X-Spam-RequestID'} = encrypt_to_base64($self->crypto_key, $id);

    my $key_data = undef;

    # shortcut for generating final responses: takes HTTP response code, body content, and hash of things to add to log_task
    my $responder = sub {
        my $code    = shift;
        my $body    = shift;
        my %params  = @_;

        if (defined $key_data && $key_data->[PRIV_send_confidence] && exists $params{confidence}) {
            $headers{'X-Spam-Confidence'} = $params{confidence};
            if (defined $params{confidence}) {
                $headers{'X-Spam-Certain'}
                    = $params{confidence} >= $self->_certainty_threshold ? 'true' : 'false';
            }
            else {
                $headers{'X-Spam-Certain'} = 'true';
            }
        }

        for my $thing (qw/rating confidence factors/) {
            $log_task{$thing} = $params{$thing} if defined $params{$thing};
        }

        $self->_generate_response($code, $body, \%headers, \%tasks, %params)
    };

    if (ref $params ne 'HASH') {
        return $responder->(
            500     => 'Internal server error',
            error   => 'serotype_query params not a hash',
        );
    }

    # decode parameters from non-utf8 encodings
    $decoded_params = SpamSvc::Serotype::Util::Encode::decode_http_params($params);

    # {{{ validate key and IP
    $key_data = $self->_get_key_data($api_key, $ip);

    if (!defined $key_data) {
        return $responder->(
            200     => 'Invalid API key',
            error   => 'Invalid API key'
        );
    }

    my $plugin;
    if (defined $key_data->[CLIENT_class_id]) {
        $plugin = $self->{keyplugins}{ $key_data->[CLIENT_class_id] };
    }

    if (
        $plugin &&
        $plugin->can('check_ip') &&
        $plugin->check_ip($api_key, $key_data, $ip) == KEY_DENY
    ) {
        return $responder->(
            401     => 'Not allowed for this key',
            error   => 'operation disallowed for key'
        );
    }

    # we now have a valid client id
    $log_task{client_dim_id} = $key_data->[CLIENT_id];

    if (!defined $key_data->[CLIENT_last_ip] || $ip ne $key_data->[CLIENT_last_ip]) {
        $log_task{key_ip_changed} = 1;
    }

    # NB: akismet returns user errors as with status 200; only ISEs generate 5xx

    if ($action eq 'verify-key') {
        if ($key_data->[PRIV_enabled]) {
            return $responder->(200 => 'valid');
        }
        else {
            return $responder->(
                200     => 'invalid',
                error   => 'key disabled'
            );
        }
    }

    # must be auth'ed now
    if (!$key_data || !$key_data->[PRIV_enabled]) {
        return $responder->(
            200     => 'Invalid API key',
            error   => 'invalid key'
        );
    }

    # }}}

    # redispatch feedback notifications to log worker
    if ($action eq 'notify') {
        $tasks{serotype_update_log} = {
            id      => $id,
            api_key => $api_key,
            params  => $decoded_params,
        };
        return $responder->(200 => 'Update received, thank you.');
    }

    if ($key_data->[PRIV_send_confidence]) {
        # for now, anybody trustworthy enough to get a confidence score can know version info as well
        $headers{'X-Spam-Processor'} = $self->{ident};
    }

    # {{{ check for critical parameters
    for my $param (qw/ comment_author_url comment_type /) {
        if (!defined $decoded_params->{$param}) {
            return $responder->(
                200     => 'Invalid request',
                error   => "missing $param"
            );
        }
    } # }}}

    my %extra_factors;

    # {{{ check the url's well-formedness and whitelist status
    my $url = $decoded_params->{comment_author_url};
    my $url_is_well_formed = 0;
    my $url_whitelisted_domain = undef;
    if ($url =~ m{^https?://([^/]+)}i) {
        my $url_host = lc $1;

        $url_is_well_formed = 1;

        # check domain and its parents against domain whitelist
        my @host_pieces = split /\./, $url_host;
        my @parent_domain = (pop @host_pieces); # start with two pieces, just below tld
        @parent_domain = join('.', @parent_domain);
        while (@host_pieces) {
            unshift @parent_domain, pop @host_pieces;
            my $parent_domain = join '.', @parent_domain;
            if ($self->_get_domain_from_memcache_or_db('whitelist', $parent_domain)) {
                $url_whitelisted_domain = $parent_domain;
                $extra_factors{DomainIsWhitelisted} = 'yes';
                last;
            }
            elsif ($self->_get_domain_from_memcache_or_db('blacklist', $parent_domain)) {
                if ($self->{config}{domain_lists}{hard_blacklist}) {
                    return $responder->(
                        _rating($SPAM),
                        confidence  => 1.0,
                        factors     => { "Blacklisted*$parent_domain" => 1 },
                    );
                }
                else {
                    $extra_factors{DomainIsBlacklisted} = 'yes';
                    last;
                }
            }
        }
    } # }}}

    # {{{ trackback handler
    if ($decoded_params->{comment_type} =~ /^(?:track|ping)back$/i) {

        if ($action eq 'comment-check') {

            if (!$url_is_well_formed) {
                # URL check is strict since URL is machine-generated
                return $responder->(
                    _rating($SPAM),
                    confidence  => 1.0,
                    factors     => { "MalformedURL" => 1 },
                );
            }

            if (defined $url_whitelisted_domain) {
                my $is_fetchable;
                eval {
                    $is_fetchable = $self->_url_is_fetchable($url);
                };
                if ($@) {
                    return $responder->(
                        500     => 'Internal Server Error',
                        error   => "LWP get failed while fetching trackback link: $@",
                    );
                }
                elsif ($is_fetchable) {
                    return $responder->(
                        _rating($HAM),
                        confidence  => 1.0,
                        factors     => { "Whitelisted*$url_whitelisted_domain" => 0 },
                    );
                }
                else {
                    return $responder->(
                        _rating($SPAM),
                        confidence  => 1.0,
                        factors     => { "Unfetchable*$url" => 1 },
                    );
                }
            }
            # neither domain nor any parent was on the whitelist
            return $responder->(
                _rating($SPAM),
                confidence  => 1.0,
                factors     => { "NotWhitelisted*$url" => 1 },
            );
        }
        elsif ($action =~ /^submit-(ham|spam)$/) {
            my $type = $1;
            my $reported_rating = $type eq 'ham' ? $HAM : $SPAM;
            if (
                ($reported_rating == $HAM  && !$key_data->[PRIV_may_train_ham]) ||
                ($reported_rating == $SPAM && !$key_data->[PRIV_may_train_spam])
            ) {
                return $responder->(
                    200     => 'Not authorized',
                    error   => "key not allowed to report $type"
                );
            }
            else {
                # these reports aren't presently handled automatically. ham
                # reports don't matter, and spam reports can cause post-hoc
                # whitelist purging via log analysis
                return $responder->(200 => 'Feedback received.');
            }
        }
        else {
            warn tstamp . "serotype_query saw unexpected action $action (for trackback)";
            return $responder->(
                500     => 'Internal Server Error',
                error   => "serotype_query saw unexpected action $action"
            );
        }
    } # }}}

    # {{{ check for pieces of the request that have been seen too frequently
    for my $object (keys %{ $self->{config}{frequency} }) {
        my $key = $decoded_params->{$object};
        next if
            !defined $key ||
            (
                defined $self->{config}{frequency}{$object}{min_length} &&
                length $key < $self->{config}{frequency}{$object}{min_length}
            );

        # don't store giant strings in memcached; use store_hashed for data
        # when key length may exceed memcached limit of 250 chars
        $key = md5_base64($key) if $self->{config}{frequency}{$object}{store_hashed};

        # get the score while updating with current time
        my ($score) = $self->{request_trackers}{$object}->hit($key);

        if ($score > $self->{config}{frequency}{$object}{hard_limit}) {
            return $responder->(
                _rating($SPAM),
                confidence  => 1.0,
                factors     => { "TooFrequent*$object" => 1 },
            );
        }

        # XXX add a meta header with this data for format_message
    } # }}}

    # {{{ check rules
    for my $rule (keys %{ $self->{config}{rules} }) {
        if (my $rule_config = $self->{config}{rules}{$rule}) {
            my ($rating, $factor, $confidence) = $self->{rule_box}->test(
                $rule => {
                    settings => $rule_config->{settings},
                    params   => $decoded_params,
                    ip       => $ip,
                }
            );

            $factor ||= $rule_config->{factor};
            $confidence = 1.0 unless defined $confidence;

            if (defined $rating && ($rating == $SPAM || $rating == $HAM)) {
                # rule gave an affirmative response

                if ($rule_config->{mode} eq 'hard') {
                    # hard reject/accept
                    return $responder->(
                        _rating($rating),
                        confidence  => $confidence,
                        factors     => { $factor => ($rating == $SPAM ? 1 : 0) },
                    );
                }
                elsif ($rule_config->{mode} eq 'soft') {
                    # just add as a factor for connector to consider
                    $extra_factors{ $rule_config->{factor} } = printable_rating($rating);
                }
            }
        }
    }
    # }}}

    my $email_text = SpamSvc::Serotype::Transformer::format_message($decoded_params, $api_key, $ip, \%extra_factors);

    # {{{ give plugins a whack at composed text before sending to content filter backend
    if ($plugin) {
        if ($plugin->can('query_pre_content_check')) {
            my $dispo = $plugin->query_pre_content_check($api_key, $key_data, $ip, \$email_text);
            if ($dispo == $SPAM || $dispo == $HAM) {
                $log_task{rating}      = $dispo;
                return $responder->(
                    _rating($dispo),
                    confidence  => 1.0,
                    factors     => { 'Plugin*' . $plugin->special_class_name() => ($dispo == $SPAM ? 1 : 0) },
                );
            }
        }

        $plugin->modify_content($key_data, \$email_text) if $plugin->can('modify_content');
    } # }}}

    # use global or per-client user?
    my $connector = $self->connector;
    if ($connector->can('user')) {
        if ($self->{config}{global_user_only}) {
            $connector->user($self->{config}{global_username});
        }
        else {
            $connector->user($key_data->[CLIENT_backend_id]);
        }
    }

    if ($action eq 'comment-check') {
        if (!$key_data->[PRIV_may_query]) {
            return $responder->(
                401     => 'Not allowed for this key',
                error   => 'key may not query'
            );
        }

        my ($rating, $confidence, $factors);
        eval {
            $rating = $connector->classify_email($email_text);
            $confidence = $connector->get_confidence();
            $factors = $connector->get_factors() if $connector->can('get_factors');
        };
        if ($@) {
            return $responder->(
                500     => 'Internal Server Error',
                error   => "classify_email failed: $@"
            );
        }

        if ($rating == $SPAM || $rating == $HAM) {
            return $responder->(
                _rating($rating),
                confidence  => $confidence,
                factors     => $factors,
            );
        }
        else {
            return $responder->(
                500     => 'Internal Server Error',
                error   => 'expected HAM or SPAM rating',
            );
        }
    }
    elsif ($action =~ /^submit-(ham|spam)$/) {
        my $type = $1;
        my $reported_rating = $type eq 'ham' ? $HAM : $SPAM;

        if (
            ($reported_rating == $HAM  && !$key_data->[PRIV_may_train_ham]) ||
            ($reported_rating == $SPAM && !$key_data->[PRIV_may_train_spam])
        ) {
            return $responder->(
                200     => 'Not authorized',
                error   => "key not allowed to report $type",
            );
        }

        $log_task{success} = 1;

        # submit another job to train the backend
        $tasks{serotype_train} = {
            id          => $log_task{id},
            disposition => $reported_rating,
            email       => $email_text,
            key_data    => $key_data,
        };

        return $responder->(200 => 'Feedback received.');
    }
    else {
        warn tstamp . "serotype_query saw unexpected action $action";
        return $responder->(
            500     => 'Internal Server Error',
            error   => "serotype_query saw unexpected action $action",
        );
    }
} # }}}

sub _rating # {{{
{
    my $rating = shift;
    return (
        200         => ($rating == $SPAM ? 'true' : 'false'),
        rating      => $rating,
    );
} # }}}

sub _url_is_fetchable # {{{
{
    my SpamSvc::Serotype::Workers::Query $self = shift;
    my $url = shift;
    my $response = $self->{ua}->get($url);
    return $response->is_success ? 1 : 0;
} # }}}

sub _get_domain_from_memcache_or_db # {{{
{
    my SpamSvc::Serotype::Workers::Query $self = shift;
    my $list   = shift;
    my $domain = shift;
    my $obj;
    my $mc_key = "serotype:$list:$domain";
    my $mc = $self->{memcache};
    if ($mc) {
        $obj = $mc->get($mc_key);
        return $obj if defined $obj;
    }
    # check if the domain is on the list
    return $self->_exec_query( qw/ client /, "fetch_${list}ed_domain", sub {
        my $sth = shift;
        $sth->execute($domain);
        $obj = $sth->fetchrow_arrayref();
        if (defined $obj && @$obj) {
            $mc && $mc->set($mc_key, 1, $self->{config}{domain_lists}{exists_expiry});
            return 1;
        }
        $mc && $mc->set($mc_key, 0, $self->{config}{domain_lists}{missing_expiry});
        return 0;
    });
} # }}}

sub _certainty_threshold # {{{
{
    my SpamSvc::Serotype::Workers::Query $self = shift;

    my $mc_key = 'serotype:certainty_threshold';

    my $mc = $self->{memcache};
    if ($mc) {
        my $threshold = $mc->get($mc_key);
        return $threshold if defined $threshold;
        $mc->set($mc_key, $self->{config}{certainty_threshold});
    }
    else {
        return $self->{config}{certainty_threshold};
    }
} # }}}

1;

# vim: foldmethod=marker
