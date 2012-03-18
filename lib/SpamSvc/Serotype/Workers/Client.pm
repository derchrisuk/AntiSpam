package SpamSvc::Serotype::Workers::Client;

use strict;
use warnings;

use Carp;
use SpamSvc::Serotype::GearmanWorker;
use SpamSvc::Serotype::KeyPlugin;
use SpamSvc::Connector ':all';
use SpamSvc::Timestamp;
use Storable qw/nfreeze thaw/;
use Time::HiRes;

use base 'SpamSvc::Serotype::GearmanWorker', 'Exporter';

use fields (
    'keyplugins',   # hash of special_class_id to handler objects for unknown apikeys
);

sub new # {{{
{
    my $class = shift;
    my $ref = ref $class || $class;

    my SpamSvc::Serotype::Workers::Client $self = SpamSvc::Serotype::GearmanWorker->new(@_);
    bless $self, $class;

    my $config = $self->{config};

    $self->_prepare_statement_handles('client');

    # populate cache of special class names
    my $special_classes_data =
        $self->{dbs}{client}{dbh}->selectall_arrayref("SELECT name, special_class_id FROM special_class");
    my %special_class_ids;
    %special_class_ids = map {@$_} @$special_classes_data if $special_classes_data;

    if (exists $config->{apikey_plugins}) {
        for my $plugin (@{ $config->{apikey_plugins} }) {
            my $class = "SpamSvc::Serotype::KeyPlugin::$plugin";
            if (eval "require $class; 1") {
                my $name = $class->special_class_name;
                my $id = $special_class_ids{$name};
                if (!defined $id) {
                    $self->_exec_query( qw/ client add_special_class_id /, sub { shift->execute($name) } );
                    # lookup rather than last_insert_id since another worker may have beat us to it
                    ($id) = $self->_exec_query(qw/ client get_special_class_id /, sub {
                        my $sth = shift;
                        $sth->execute;
                        return $sth->fetchrow_array();
                    });
                    croak tstamp . "couldn't add special_class_id=$name" unless defined $id;
                    $special_class_ids{$name} = $id;
                }
                $self->{keyplugins}{$id} = $class->new();
            }
            else {
                carp tstamp . "$$: Failed to load key plugin $class: $@";
            }
        }
    }


    return $self;
} # }}}

sub _get_key_data_from_db # {{{
{
    my SpamSvc::Serotype::Workers::Client $self = shift;
    my $key = shift;

    my $obj;
    my $mc_key = "serotype:keydata:$key";

    my $mc = $self->{memcache};
    if ($mc) {
        $obj = $mc->get($mc_key);
        return $obj if $obj;
    }

    return $self->_exec_query( qw/ client fetch_key_data /, sub {
        my $sth = shift;
        $sth->execute($key);
        $obj = $sth->fetchrow_arrayref();
        $mc->add($mc_key, $obj) if $mc && $obj;
        return $obj;
    });
} # }}}

my $backend_id_namespace = 's_'; # prefix to avoid possibility of trampling on existing backend user

sub _get_key_data # {{{
{
    my SpamSvc::Serotype::Workers::Client $self = shift;
    my $key = shift;
    my $ip  = shift;

    my $data = $self->_get_key_data_from_db($key);

    if (!defined $data) {
        # haven't seen this api key before.

        # sensible default privs
        my %key_props = (
            special_class_id    => undef,
            trust               => $self->{config}{reputation}{minimum},
            trust_mutable       => 1,
            enabled             => 1,
            may_query           => 1,
            may_train_spam      => 1,
            may_train_ham       => 1,
            may_follow_link     => 0,
            send_confidence     => 0,
        );

        # allow loadable modules to tweak key privs and claim ownership
        for my $id (keys %{ $self->{keyplugins} }) {
            my $plugin = $self->{keyplugins}{$id};
            my $ret = $plugin->inspect_new_key($key, \%key_props, $self->{config}, $ip);
            return undef if $ret == KEY_DENY;
            if ($ret == KEY_CLAIMED) {
                $key_props{special_class_id} = $id;
                last;
            }
        }

        # generate a sufficiently unique backend_id for it.
        my $backend_id = sprintf "%s%x", $backend_id_namespace, $self->{yuid}->get_id;

        # create user in DB
        $self->_exec_query(qw/ client create_key_data /, sub {
            shift->execute(
                $backend_id,
                $key,
                $key_props{special_class_id},
                $key_props{trust},
                map {$_ ? 1 : 0} @key_props{qw/
                    trust_mutable
                    enabled
                    may_query
                    may_train_spam
                    may_train_ham
                    may_follow_link
                    send_confidence
                /},
                $ip
            );
        });

        # then retry fetch
        $data = $self->_get_key_data_from_db($key); # might still be undef on insert error

        carp tstamp . "key fetch retry failed" unless $data;
    }

    return $data;
} # }}}

# {{{ constants
# must match order of fetch_key_data query
use constant CLIENT_id              => 0;
use constant CLIENT_api_key         => 1;
use constant CLIENT_class_id        => 2;
use constant CLIENT_backend_id      => 3;
use constant CLIENT_last_ip         => 4;
use constant CLIENT_trust           => 5;
use constant PRIV_enabled           => 6;
use constant PRIV_may_query         => 7;
use constant PRIV_may_train_spam    => 8;
use constant PRIV_may_train_ham     => 9;
use constant PRIV_may_follow_link   => 10;
use constant PRIV_send_confidence   => 11;

our @EXPORT = qw/
CLIENT_id
CLIENT_api_key
CLIENT_class_id
CLIENT_backend_id
CLIENT_last_ip
CLIENT_trust
PRIV_enabled
PRIV_may_query
PRIV_may_train_spam
PRIV_may_train_ham
PRIV_may_follow_link
PRIV_send_confidence
/;

# }}}

1;

# vim: foldmethod=marker
