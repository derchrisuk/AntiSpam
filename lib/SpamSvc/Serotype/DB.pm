package SpamSvc::Serotype::DB;

use strict;
use warnings;

use Carp;
use DBI;
use YAML::Syck;

=head1 SpamSvc::Serotype::DB

Convenience module for obtaining a MySQL database handle. Attempts to require
as little work as possible to use in various server environments.

=head2 SpamSvc::Serotype::DB->connect(%params)

Available parameters:

=over 4

* I<preset>/I<preset_file>

Read parameters for the named preset from the given file or ~/.dbpresets.yaml if not given.

* I<driver>

DBI driver to use. Defaults to mysql. Support for others is very limited.

* I<host>/I<port>

Hostname and TCP port number where server listens.

* I<sock> (instead of host/port)

Local UNIX socket where server listens. If both I<host> and I<sock> are
omitted, connect() checks for the existence of a local socket in known
locations, then falls back to connecting via TCP to localhost.

* I<name>

Database name.

* I<user>

MySQL user name.

* I<password>

Above user's password.

* I<server_prepare>

If true, attempt to use server-side prepared statement handles.

* I<fatal>

When true (default), all DBI errors raise an exception.

* I<utf8>

If true, attempts to retrieve data from the server in utf8 format.

=back

=cut

sub connect {
    my $package = shift;

    my $params;
    if (@_ == 1 && ref $_[0] eq 'HASH') {
        $params = shift;
    }
    else {
        $params = {@_};
    }

    if (my $preset = $params->{preset}) {
        my $file = $params->{preset_file};
        if (!$file) {
            my $homedir = (getpwuid $>)[7];
            my $homefile = "$homedir/.dbpresets.yaml";
            if (-e $homefile) {
                $file = $homefile;
            }
            else {
                croak "no preset file\n";
            }
        }

        my $presets = LoadFile($file);

        my $conf = $presets->{$preset};
        die "no such preset $preset in $file" unless $conf;
        return $package->connect($conf);
    }

    my %p = (
        driver      => 'mysql',
        port        => 3306,
        password    => '',
        fatal       => 1,
        %$params,
    );

    if (!defined $p{host} && !defined $p{sock}) {
        for (qw{
            /tmp/mysql.sock
            /var/lib/mysql/mysql.sock
        }) {
            if (-w $_) {
                $p{sock} = $_;
                last;
            }
        }
        unless ($p{sock}) {
            $p{host} = 'localhost';
        }
    }

    # if either is missing, guess that dbname=username
    if (defined $p{name} && !defined $p{user}) {
        $p{user} = $p{name};
    }
    elsif (!defined $p{name} && defined $p{user}) {
        $p{name} = $p{user};
    }

    my $dsn;
    if (defined $p{sock}) {
        croak "sock $p{sock} isn't writable" unless -w $p{sock};
        $dsn = "DBI:mysql:database=$p{name};mysql_socket=" . $p{sock};
    }
    elsif ($p{host} =~ m{^/}) {
        croak "sock $p{host} isn't writable" unless -w $p{host};
        $dsn = "DBI:mysql:database=$p{name};mysql_socket=" . $p{host};
    }
    else {
        $dsn = "DBI:$p{driver}:database=$p{name};host=$p{host};port=$p{port}";
    }
    $dsn .= ';mysql_server_prepare=1' if $p{server_prepare};

    my $dbh = DBI->connect($dsn, $p{user}, $p{password}, $p{fatal} ? {RaiseError => 1} : ());

    if ($p{utf8}) {
        $dbh->{mysql_enable_utf8} = 1;
        $dbh->do(q{SET NAMES 'utf8'});
    }

    return $dbh;
}

sub preset {
    my $package = shift;
    my $preset = shift;
    my $file = shift;
    return $package->connect(preset => $preset, $file ? (preset_file => $file) : ());
}

sub new {
    my $ref = shift;
    my $class = ref $ref || $ref;

    my $params;
    if (@_ == 1 && ref $_[0] eq 'HASH') {
        $params = shift;
    }
    else {
        $params = {@_};
    }

    if (my $preset = $params->{preset}) {
        my $file = $params->{preset_file};
        if (!$file) {
            my $homedir = (getpwuid $>)[7];
            my $homefile = "$homedir/.dbpresets.yaml";
            if (-e $homefile) {
                $file = $homefile;
            }
            else {
                croak "no preset file\n";
            }
        }

        my $presets = LoadFile($file);

        my $conf = $presets->{$preset};
        die "no such preset $preset in $file" unless $conf;
        return $class->new($conf);
    }

    my %p = (
        driver      => 'mysql',
        port        => 3306,
        password    => '',
        fatal       => 1,
        %$params,
    );

    if (!defined $p{host} && !defined $p{sock}) {
        for (qw{
            /tmp/mysql.sock
            /var/lib/mysql/mysql.sock
        }) {
            if (-w $_) {
                $p{sock} = $_;
                last;
            }
        }
        unless ($p{sock}) {
            $p{host} = 'localhost';
        }
    }

    # if either is missing, guess that dbname=username
    if (defined $p{name} && !defined $p{user}) {
        $p{user} = $p{name};
    }
    elsif (!defined $p{name} && defined $p{user}) {
        $p{name} = $p{user};
    }

    if (defined $p{sock}) {
        croak "sock $p{sock} isn't writable" unless -w $p{sock};
        $p{dsn} = "DBI:mysql:database=$p{name};mysql_socket=" . $p{sock};
    }
    elsif ($p{host} =~ m{^/}) {
        croak "sock $p{host} isn't writable" unless -w $p{host};
        $p{dsn} = "DBI:mysql:database=$p{name};mysql_socket=" . $p{host};
    }
    else {
        $p{dsn} = "DBI:$p{driver}:database=$p{name};host=$p{host};port=$p{port}";
    }
    $p{dsn} .= ';mysql_server_prepare=1' if $p{server_prepare};

    return bless \%p, $class;
}

sub new_from_preset {
    my $package = shift;
    my $preset = shift;
    my $file = shift;
    return $package->new(preset => $preset, $file ? (preset_file => $file) : ());
}

sub dbh {
    my $self = shift;

    my $dbh = $self->{dbh} = DBI->connect($self->{dsn}, $self->{user}, $self->{password}, $self->{fatal} ? {RaiseError => 1} : ());

    if ($self->{utf8}) {
        $dbh->{mysql_enable_utf8} = 1;
        $dbh->do(q{SET NAMES 'utf8'});
    }

    return $dbh;
}

sub driver          { return shift->{driver} }
sub dsn             { return shift->{dsn} }
sub fatal           { return shift->{fatal} }
sub host            { return shift->{host} }
sub name            { return shift->{name} }
sub password        { return shift->{password} }
sub port            { return shift->{port} }
sub server_prepare  { return shift->{server_prepare} }
sub sock            { return shift->{sock} }
sub user            { return shift->{user} }
sub utf8            { return shift->{utf8} }

1;
