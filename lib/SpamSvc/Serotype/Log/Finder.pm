package SpamSvc::Serotype::Log::Finder;

# finds log records in partitioned serotype_log tables

use strict;
use warnings;

use Carp;
use Compress::Zlib 'uncompress';
use DBI;
use File::Basename;
use FindBin '$Bin';
use Getopt::Long;
use SpamSvc::Serotype::Config 'load_config';
use SpamSvc::Serotype::Log::Meta;
use SpamSvc::Serotype::Util qw/ str2time str2midnight time2date /;
use Storable 'thaw';
use YAML::Syck qw/ LoadFile Dump /;

sub new {
    my $class = shift;
    my $ref = ref $class || $class;
    my $self = {
        log_host        => 'localhost',
        log_port        => 3306,
        log_name        => 'serotype_log',
        log_user        => 'serotype',
        log_password    => '',
        log_servprep    => 0,
        client_host     => 'localhost',
        client_port     => 3306,
        client_name     => 'serotype',
        client_user     => 'serotype',
        client_password => '',
        params          => 1,
        factors         => 1,
        reviews         => 1,
        ext_meta        => 0,
        notifications   => 0,
        @_,
    };
    bless $self, $class;

    if (defined $self->{dates}) {
        my @times = sort {$a<=>$b} map {str2midnight($_)} @{ $self->{dates} };
        $self->{search_dates} = [map {scalar localtime $_} @times];
        $self->{_start_time}  = $times[0];
        $self->{_end_time}    = $times[-1] + 24*60*60 - 1;
    }
    elsif (defined $self->{start}) {
        $self->{_start_time} = str2time($self->{start});
        $self->{_end_time} = defined $self->{end} ? str2time($self->{end}) : time;
        for (my $time = $self->{_start_time}; $time <= $self->{_end_time}; $time += 60*60*24) {
            push @{ $self->{search_dates} }, scalar localtime $time;
        }
    }

    $self->{log_dbh} = $self->_connect_to_log_db();

    # get a list of matching tables
    $self->{tables} = {
        map {$_=>1}
        grep { /^param_dim/ || /^request_log/ || /^factors_dim/ || /^ext_meta/ || /^reviews$/ }
        map {$_->[0]}
        @{ $self->{log_dbh}->selectall_arrayref('SHOW TABLES') }
    };

    $self->{factors} = 1 if $self->{required_factors};

    if ($self->{serotype_config}) {
        $self->{meta} = SpamSvc::Serotype::Log::Meta->new(
            load_config($self->{serotype_config})
        );
    }
    elsif ($self->{ext_meta}) {
        croak "can't lookup ext_meta data without serotype_config given";
    }

    return $self;
}

sub _connect_to_log_db {
    my $self = shift;
    $self->{log_dbh} = undef;
    my $log_dsn = "DBI:mysql:database=$self->{log_name};host=$self->{log_host};port=$self->{log_port}";
    $log_dsn .= ';mysql_server_prepare=1' if $self->{log_servprep};
    print STDERR "log_dsn=$log_dsn\n" if $self->{debug};
    $self->{log_dbh} = DBI->connect($log_dsn, $self->{log_user}, $self->{log_pass}, {RaiseError => 1});
}

sub generate_reqlog_sql {
    my $self        = shift;
    my $db_date     = shift;
    my $ids_only    = shift;
    my %conditions  = @_;

    my $request_log = "request_log_$db_date";
    my $param_dim   = "param_dim_$db_date";
    my $factors_dim = "factors_dim_$db_date";

    return undef unless exists $self->{tables}{$request_log};

    my @columns = (qw/ request_log_id api_key action worker type success rating confidence trained_backend error start_time end_time /, 'cip.ip AS ip', 'uip.ip AS user_ip');

    my $get_params;
    if ($self->{params} && defined $param_dim && exists $self->{tables}{$param_dim}) {
        $get_params = 1;
        push @columns, 'params';
    }
    else {
        $get_params = 0;
        push @columns, 'NULL';
    }

    my $get_factors;
    if ($self->{factors} && defined $factors_dim && exists $self->{tables}{$factors_dim}) {
        $get_factors = 1;
        push @columns, 'factors';
    }
    else {
        $get_factors = 0;
        push @columns, 'NULL';
    }

    @columns = 'request_log_id' if $ids_only;

    my $sql = sprintf "SELECT %s\nFROM   $request_log\n", join ",\n       ", @columns;

    if (!$ids_only) {
        $sql .= "JOIN   interesting_ids USING (request_log_id)\n";
    }

    $sql .= "JOIN   api_key_dim USING (api_key_dim_id)\n"
        if !$ids_only || $conditions{api_key};

    $sql .= "JOIN   action_dim  USING (action_dim_id)\n"
        if !$ids_only || $conditions{action} || $conditions{training_only}
                      || $conditions{accepted_training_only} || $conditions{skip_notify};

    $sql .= "JOIN   ip_dim cip  ON    cip.ip_dim_id = $request_log.ip_dim_id\n"
        if !$ids_only;

    $sql .= "JOIN   ip_dim uip  ON    uip.ip_dim_id = $request_log.user_ip_dim_id\n"
        if !$ids_only || $conditions{user_ip};

    $sql .= "JOIN   worker_dim  USING (worker_dim_id)\n"
        if !$ids_only;

    $sql .= "JOIN   type_dim    USING (type_dim_id)\n"
        if !$ids_only || $conditions{type};

    if (!$ids_only) {
        $sql .= "LEFT\nJOIN   $param_dim USING (param_dim_id)\n" if $get_params;
        $sql .= "LEFT\nJOIN   $factors_dim USING (factors_dim_id)\n" if $get_factors;
    }

    if (%conditions) {
        my @conds = values %conditions;
        s/REQUEST_LOG/$request_log/ for @conds;
        $sql .= 'WHERE  ' . join "\nAND    ", @conds;
    }

    if ($self->{order_by_date}) {
        $sql .= "\nORDER BY start_time ASC";
    }
    else {
        $sql .= "\nORDER BY request_log_id ASC";
    }
    #$sql .= "\nLIMIT 50000" if $ids_only; # XXX debug

    warn "SQL:\n$sql\n" if $self->{debug};

    return "$sql\n";
}

sub find {
    my $self = shift;
    my $callback = shift;

    croak 'no callback provided' unless $callback;
    croak 'callback is not a coderef' unless ref $callback eq 'CODE';

    my %conditions;
    if (defined $self->{api_key}) {
        my $ref = $self->{log_dbh}->selectrow_arrayref('SELECT api_key_dim_id FROM api_key_dim WHERE api_key=?', undef, $self->{api_key});
        croak "couldn't get api_key id for $self->{api_key}" unless $ref && @$ref;
        my $dim_id = $ref->[0];
        warn "Restricting to apikey=$self->{api_key} (api_key_dim_id=$dim_id)\n" if $self->{debug};
        $conditions{api_key} = sprintf "api_key_dim_id=%s", $self->{log_dbh}->quote($dim_id);
    }

    $conditions{id} =
        sprintf "request_log_id=%s", $self->{log_dbh}->quote($self->{id})
        if $self->{id};

    $conditions{user_ip} =
        sprintf "uip.ip=%s",         $self->{log_dbh}->quote($self->{user_ip})
        if $self->{user_ip};

    $conditions{action} =
        sprintf 'action=%s',         $self->{log_dbh}->quote($self->{action})
        if $self->{action};

    $conditions{training_only} =
        sprintf q{action IN ('submit-spam', 'submit-ham')}
        if $self->{training_only};

    $conditions{accepted_training_only} =
        sprintf q{action IN ('submit-spam', 'submit-ham') AND trained_backend=1}
        if $self->{accepted_training_only};

    $conditions{skip_notify} =
        sprintf q{action != 'notify'}
        if !$self->{notifications};

    $conditions{type} =
        sprintf 'type=%s',           $self->{log_dbh}->quote($self->{type})
        if $self->{type};

    $conditions{rating} =
        sprintf 'rating=%s',         $self->{log_dbh}->quote($self->{rating})
        if $self->{rating};

    $conditions{min_confidence} =
        sprintf 'confidence>=%s',    $self->{log_dbh}->quote($self->{min_confidence})
        if $self->{min_confidence};

    $conditions{max_confidence} =
        sprintf 'confidence<=%s',    $self->{log_dbh}->quote($self->{max_confidence})
        if $self->{max_confidence};

    $conditions{skip_unreviewed} =
        'EXISTS (SELECT * FROM reviews WHERE REQUEST_LOG.request_log_id = reviews.request_log_id)'
        if $self->{skip_unreviewed};

    $conditions{skip_ok} =
        'error IS NOT NULL'
        if $self->{skip_ok};

    my %expanded_search_dates;
    if (defined $self->{search_dates}) {
        for my $date (@{ $self->{search_dates} }) {
            #for my $offset (-1,0,1) {
            for my $offset (0) {
                my @l = localtime(str2time($date)+86400*$offset);
                $l[5] += 1900; # year
                $l[4]++; # month

                my $fixed_date = sprintf "%04d-%02d-%02d", @l[5, 4, 3];
                $expanded_search_dates{$fixed_date}++;
            }
        }

        # don't need this if date_ids are inserted correctly
        #my @date_ids = map {$self->date_id($_)} sort keys %expanded_search_dates;
        #$conditions{date_id} = sprintf "REQUEST_LOG.date_id IN (%s)", join ',', @date_ids;
    }

    my %table_dates;
    for my $table (keys %{ $self->{tables} }) {
        if ($table =~ /_(\d{4}_\d\d_\d\d)$/) {
            $table_dates{$1}++;
        }
    }

    if (defined $self->{id}) {
        # check for the id in the map
        my $ref = $self->{log_dbh}->selectrow_arrayref('SELECT the_day FROM date_dim JOIN id_date_map USING (date_id) WHERE request_log_id=?', undef, $self->{id});
        if ($ref) {
            # found it in the map
            (my $date = $ref->[0]) =~ tr/-/_/;
            %table_dates = ($date => 1);
        }
    }

    my $fetched = 0;
    for my $db_date (sort keys %table_dates) {
        my $dash_date = $db_date;
        $dash_date =~ tr/_/-/;
        next if $self->{search_dates} && !exists $expanded_search_dates{$dash_date};

        $self->_connect_to_log_db();
        my $dbh = $self->{log_dbh};

        next if $self->{pretend};

        # load interesting request_log_id's into a temporary table
        $dbh->do('DROP TEMPORARY TABLE IF EXISTS interesting_ids');
        $dbh->do('CREATE TEMPORARY TABLE interesting_ids (request_log_id BIGINT UNSIGNED PRIMARY KEY)');
        $dbh->do('INSERT INTO interesting_ids ' . $self->generate_reqlog_sql($db_date, 1, %conditions));

        if ($self->{debug}) {
            my $sth = $dbh->prepare('SELECT COUNT(*) from interesting_ids');
            $sth->execute();
            printf STDERR "Matching requests: %d\n", $sth->fetchrow_array;
        }

        my %reviews;
        if ($self->{reviews} && exists $self->{tables}{reviews}) {
            $self->{debug} && warn "Gathering reviews\n";

            use constant {
                REVIEW_ID               => 0,
                REVIEW_REVIEWER         => 1,
                REVIEW_RATING           => 2,
                REVIEW_AUTHORITATIVE    => 3,
                REVIEW_CONFIDENCE       => 4,
                REVIEW_START_TIME       => 5,
                REVIEW_END_TIME         => 6,
            };

            my $sth = $dbh->prepare(<<'            END_SQL');
             SELECT request_log_id,
                    reviewer,
                    rating,
                    authoritative,
                    confidence,
                    start_time,
                    end_time

               FROM reviews

               JOIN interesting_ids
              USING (request_log_id)

               JOIN reviewers
              USING (reviewer_id)
            END_SQL

            $sth->execute;

            push @{ $reviews{$_->[0]} }, [@$_] while $_ = $sth->fetchrow_arrayref();
        }

        my $ext_meta_table = "ext_meta_$db_date";
        my %ext_meta;
        if ($self->{ext_meta} && exists $self->{tables}{$ext_meta_table}) {
            $self->{debug} && warn "Gathering ext_meta\n";

            my $sth = $dbh->prepare(<<"            END_SQL");
             SELECT ext_meta.*

               FROM $ext_meta_table ext_meta

               JOIN interesting_ids
              USING (request_log_id)
            END_SQL

            $sth->execute;

            push @{ $ext_meta{$_->[0]} }, [@$_] while $_ = $sth->fetchrow_arrayref();
        }

        my $sth = $self->{log_dbh}->prepare($self->generate_reqlog_sql($db_date, 0, %conditions));
        $sth->execute;

        $sth->bind_columns(\(my (
            $request_log_id,
            $api_key_out,
            $action,
            $worker,
            $type,
            $success,
            $rating,
            $confidence,
            $trained_backend,
            $error,
            $start_time,
            $end_time,
            $ip,
            $user_ip,
            $params_frozen,
            $factors_frozen,
        )));
        while ($sth->fetch) {
            my %data = (
                id              => $request_log_id,
                api_key         => $api_key_out,
                action          => $action,
                worker          => $worker,
                type            => $type,
                success         => $success,
                rating          => $rating,
                confidence      => $confidence,
                trained_backend => $trained_backend,
                error           => $error,
                start_time      => $start_time,
                end_time        => $end_time,
                ip              => $ip,
                user_ip         => $user_ip,
                elapsed         => sprintf("%.3f", ($end_time-$start_time)/1000),
                start_print     => (scalar localtime int($start_time/1000)),
                start_date      => time2date(int($start_time/1000)),
                end_print       => (scalar localtime int($end_time/1000)),
            );

            next if defined $self->{_start_time} && ($start_time/1000) < $self->{_start_time};
            next if defined $self->{_end_time}   && ($end_time/  1000) > $self->{_end_time};

            if ($self->{params} && $params_frozen) {
                my $params = thaw uncompress $params_frozen;
                if (ref $params eq 'HASH') {
                    next if defined $self->{author} && (
                        !defined $params->{comment_author} ||
                        $params->{comment_author} !~ /$self->{author}/
                    );

                    next if defined $self->{email} && (
                        !defined $params->{comment_author_email} ||
                        $params->{comment_author_email} !~ /$self->{email}/
                    );

                    next if defined $self->{url} && (
                        !defined $params->{comment_author_url} ||
                        $params->{comment_author_url} !~ /$self->{url}/
                    );

                    next if defined $self->{body} && (
                        !defined $params->{comment_content} ||
                        $params->{comment_content} !~ /$self->{body}/
                    );

                    next if defined $self->{permalink} && (
                        !defined $params->{permalink} ||
                        $params->{permalink} !~ /$self->{permalink}/
                    );
                }
                $data{params} = $params;
            }
            else {
                next unless
                    !$self->{params} || (
                        defined $self->{author} &&
                        defined $self->{email} &&
                        defined $self->{url} &&
                        defined $self->{body}
                    );
            }

            $fetched++;

            next if $self->{count_only};

            if ($self->{factors} && $factors_frozen) {
                $data{factors} = thaw uncompress $factors_frozen;
                if (my $req = $self->{required_factors}) {
                    for my $factor (@$req) {
                        next RESULT unless exists $data{factors}{$factor};
                    }
                }
            }
            elsif ($self->{required_factors}) {
                next;
            }

            if ($self->{reviews} && $reviews{$request_log_id}) {
                my %r;
                for my $row (@{ $reviews{$request_log_id} }) {
                    @{ $r{$row->[REVIEW_REVIEWER]} }{ qw/
                        reviewer
                        rating
                        authoritative
                        confidence
                        start_time
                        end_time
                    / } = @{ $row }[
                        REVIEW_REVIEWER,
                        REVIEW_RATING,
                        REVIEW_AUTHORITATIVE,
                        REVIEW_CONFIDENCE,
                        REVIEW_START_TIME,
                        REVIEW_END_TIME
                    ];
                }
                $data{reviews} = \%r;
            }

            if ($self->{ext_meta} && $ext_meta{$request_log_id}) {
                my %e;
                for my $row (@{ $ext_meta{$request_log_id} }) {
                    my ($prop, $value) = $self->{meta}->db_row_to_prop_and_value($row);
                    $e{$prop} = $value;
                }
                $data{ext_meta} = \%e;
            }

            $callback->(\%data);

            last if defined $self->{limit} && $fetched >= $self->{limit};
        }
    }

    return $fetched;
}

sub find_once {
    my $package = shift;
    my $sub = pop @_;
    croak "last arg to find_once not a coderef" unless ref $sub eq 'CODE';
    my %args = @_;
    my $finder = $package->new(%args);
    return $finder->find($sub);
}

sub resolve_client_spec {
    my $self = shift;
    my $client_spec = shift; # may be an api key or info string

    return $self->{api_key} = undef unless defined $client_spec;

    my $client_dsn = "DBI:mysql:database=$self->{client_name};host=$self->{client_host};port=$self->{client_port}";
    my $client_dbh = DBI->connect($client_dsn, $self->{client_user}, $self->{client_pass}, {RaiseError => 1});

    my ($is_live_api_key) = @{ $client_dbh->selectrow_arrayref('SELECT COUNT(*) FROM client_dim WHERE api_key=?', undef, $client_spec) };

    if ($is_live_api_key) {
        # client_spec is an extant api_key
        return $self->{api_key} = $client_spec;
    }
    else {
        # try to pull by info record
        my $ref = $client_dbh->selectrow_arrayref('
            SELECT  api_key
            FROM    client_dim
            JOIN    client_info
            USING   (client_dim_id)
            WHERE   info = ?
            ',
            undef,
            $client_spec
        );
        if ($ref && @$ref) {
            return $self->{api_key} = $ref->[0];
        }
    }

    # neither apikey nor info string
    return $self->{api_key} = undef;
}

sub api_key {
    my $self = shift;
    my $key = shift;
    $self->{api_key} = $key if $key;
    return $self->{api_key};
}

my $date_ids;
sub date_id {
    # takes either 2007_01_01 or 2007-01-01
    my $self = shift;
    my $date = shift;
    return $date_ids->{$date} if $date_ids;

    my $ref = $self->{log_dbh}->selectall_arrayref('SELECT the_day, date_id FROM date_dim');

    for (@$ref) {
        my ($day, $date_id) = @$_;
        $date_ids->{$day} = $date_id;
        $day =~ tr/-/_/;
        $date_ids->{$day} = $date_id;
    }

    return $date_ids->{$date};
}

1;
