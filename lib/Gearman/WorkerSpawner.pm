package Gearman::WorkerSpawner;

=head1 NAME

Gearman::WorkerSpawner - Launches subclasses of L<Gearman::Worker> in their own
process for communication with a gearmand. Both in-process and external
Gearman servers may be used and can be created as appropriate.

=head1 USAGE

   # write your worker code here:

   package MyGearmanWorker;
   use base 'Gearman::Worker';

   sub new {
       my $class = shift;
       my $ref = ref $class || $class;
       my $options = shift;
       my $self = Gearman::Worker->new();
       bless $self, $class;
       $self->register_function(blah => sub { return 42 });
       return $self;
   }

   # and your client code in some Danga::Socket environment, e.g. Perlbal:

   package Perlbal::Plugin::MyPlugin;
   sub register {
       # create one manager per process
       my $worker_manager = Gearman::WorkerSpawner->new(
           gearmand     => 'inproc',
       );
       # add different workers
       $worker_manager->add_worker(
           class        => 'MyGearmanWorker',
           num_workers  => 4,
           worker_opts  => {
               foo => 3,
               bar => 1.2,
           }, # passed as second arg to MyGearmanWorker->new()
       );
       $svc->register_hook(
           MyPlugin => proxy_read_request => sub {
               $worker_manager->add_task(Gearman::Task->new(blah => '3.14'));
           }
       );
   }

=cut

use strict;
use warnings;

use Carp;
use Danga::Socket;
use Gearman::Client;
use Gearman::Client::Async;
use Gearman::Server;
use IO::Socket::INET;
use POSIX ':sys_wait_h';
use Storable qw/nfreeze thaw/;

=head1 CLASS METHODS

=over 4

=item * Gearman::WorkerSpawner->new(class => 'MyClass')

Constructor, can take the following parameters:

=over 4

=item * gearmand

Specifies the location of the Gearman server to use. This may either be a comma
separated list of host:port specs, or one of these special values:

=over 2

=item I<inproc>

Specifies that the WorkerSpawner should create a Gearman server within the
calling process. This requires that your process run a Danga::Socket loop.

=item I<external>

Specifies that the WorkerSpawner should spawn a separate process to contain a
Gearman server. The advantage of using this over running gearmand externally is
that the Gearman server process will halt itself in the event of the calling
process' demise.

=back

=item * check_period

Time in seconds between live-worker checks. Any zombie children are reaped with
C<waitpid> during the check, and enough workers are spawned to make the total
C<num_workers> again.

=item * perl

Path to the C<perl(1)> binary with which to execute workers. Defaults to
C<$^X>.

=back

Since WorkerSpawner periodically reaps any dead children of its containing
process, only a single WorkerSpawner may be created in a process (otherwise
multiple spawners would race to reap each others' children, making worker
accounting impossible). As such, new() will croak if called more than once.

=cut

our $gearmand_spec;
my $num_workers = 0;
my %kids;
my @open_slots;
my $started = 0;

sub new {
    croak "only one WorkerSpawner allowed per process" if $started;

    my $class = shift;
    my $ref = ref $class || $class;

    my %params = (
        check_period    => 1,
        perl            => $^X,
        @_
    );

    if (defined $params{gearmand}) {
        if (defined $gearmand_spec) {
            if ($gearmand_spec ne $params{gearmand}) {
                croak 'gearmand spec may not be changed after initial configuration';
            }
        }
        else {
            $gearmand_spec = $params{gearmand};
            gearman_server(); # init the server singleton if necessary
        }
    }

    croak 'gearmand location not specified' unless defined $gearmand_spec;

    my $self = bless \%params, $class;

    # spawn kids and periodically check for their demise
    my $spawner;
    $spawner = $self->{_spawner} = sub {
        $self->_check_workers();
        Danga::Socket->AddTimer($self->{check_period}, $spawner);
    };
    Danga::Socket->AddTimer(0, $spawner);

    $started = 1;

    return $self;
}

=back

=head1 OBJECT METHODS

=over 4

=item $spawner->add_worker(%options)

Add a new worker class to the manager. Can take the following parameters:

=over 4

=item * class

(Required) The package name of the L<Gearman::Worker> subclass which will
register itself for work when instantiated.

=item * num_workers

The number of worker children to spawn. If any child processes die they will be
respawned. Defaults to 1.

=item * worker_args

An opaque data structure to pass to the child process. Must be serializable via
Storable.

=item * script

Path to the script which loads the worker class and requests work . You will
almost certainly want to omit this argument, since the default value is the
path of this module itself, which acts as a suitable launcher script.

=back

=cut

use constant SLOT_NUM    => 0;
use constant SLOT_ID     => 1;
use constant SLOT_PARAMS => 2;

sub add_worker {
    my Gearman::WorkerSpawner $self = shift;
    my %params = (
        num_workers     => 1,
        @_
    );

    croak 'no class provided' unless $params{class};

    if (!exists $params{script}) {
        # exec this .pm file
        my $package_spec = __PACKAGE__ . '.pm';
        $package_spec =~ s{::}{/}g;
        my $package_file = $INC{$package_spec};
        die "couldn't determine location of myself" unless $package_file;
        $params{script} = $package_file;
    }

    # assign a slot to each worker so they can differentiate themselves based
    # on slot (like an MPI rank). @open_slots contains the slot# and startup
    # params for any slot without a live worker child.
    for my $slot_num ($num_workers..$num_workers+$params{num_workers}-1) {
        my $worker_id = sprintf '%d:%s/%s', $slot_num, $params{class}, substr rand() . '0'x16, 2, 16;
        push @open_slots, [$slot_num, $worker_id, \%params];
    }

    $num_workers += $params{num_workers};
}

=item $spawner->wait_until_all_ready()

Returns only once all worker are ready to accept jobs. Not supported with
inproc gearmand.

=cut

sub _ping_name {
    my $id = shift;
    return "ping_$id";
}

sub wait_until_all_ready {
    my Gearman::WorkerSpawner $self = shift;
    my $timeout = shift || 0.1;

    # need a synchronous client since we're not in the Danga::Socket loop yet
    croak "wait_until_all_ready not supported with inproc server"
        if $gearmand_spec eq 'inproc';

    # make sure everybody's running
    $self->_check_workers() while @open_slots;

    my $client = Gearman::Client->new(job_servers => [gearman_server()]);
    my $task_set = $client->new_task_set;

    for my $slot (values %kids) {
        $task_set->add_task(
            _ping_name($slot->[SLOT_ID]),
            undef,
            {
                timeout     => $timeout,
                retry_count => 1_000_000,
            }
        );
    }

    $task_set->wait;
}

=item $spawner->add_task($task)

Asynchronously submits a L<Gearman::Task> object to a configured Gearman server.

=cut

sub add_task {
    my Gearman::WorkerSpawner $self = shift;
    my Gearman::Task $task = shift;
    return unless $task;
    _gearman_client()->add_task($task);
}

=back

=head1 INTERNAL METHODS

=over 4

=cut

=item $spawner->gearman_server()

For in-process gearmand, returns the L<Gearman::Server> object used by the
spawner. For extra-process gearmand(s), returns a list of server host:port
specs.

=cut

# singleton server object: esp for inproc, need to keep a single server per process, not object
my $gearman_server;
sub gearman_server {
    if (!$gearman_server) {
        if ($gearmand_spec eq 'inproc') {
            # no magic required at this point, just install the server into the D::S loop
            $gearman_server = Gearman::Server->new;
        }
        elsif ($gearmand_spec eq 'external') {
            # ask OS for open listening port
            my $gearmand_port;
            eval {
                my $sock = IO::Socket::INET->new(
                    Type      => SOCK_STREAM,
                    Proto     => 'tcp',
                    Reuse     => 1,
                    Listen    => 1,
                );
                $gearmand_port = $sock->sockport;
                $sock->close;
            };
            die "failed to create listening socket: $@" if $@;

            die "couldn't find an open port for gearmand" unless $gearmand_port;

            # fork a clingy gearmand
            my $pid = fork;
            croak "fork failed: $!" unless defined $pid;
            if ($pid) {
                $gearman_server = ["127.0.0.1:$gearmand_port"];
            }
            else {
                my $parent_pid = getppid();
                $0 = 'WorkerSpawner-gearmand';
                $gearman_server = Gearman::Server->new;
                $gearman_server->create_listening_sock($gearmand_port);
                my $suicider;
                $suicider = sub {
                    exit if getppid != $parent_pid;
                    Danga::Socket->AddTimer(5, $suicider);
                };
                Danga::Socket->AddTimer(0, $suicider);
                Danga::Socket->EventLoop();
                exit 0;
            }
        }
        else {
            $gearman_server = [split /,/, $gearmand_spec];
        }
    }
    if (wantarray && ref $gearman_server eq 'ARRAY') {
        return @$gearman_server;
    }
    else {
        return $gearman_server;
    }
}

=item $spawner->_gearman_client()

Returns the L<Gearman::Client::Async> object used by the spawner.

=cut

my $gearman_client;
sub _gearman_client {
    return $gearman_client ||= Gearman::Client::Async->new(job_servers => [gearman_server()]);
}

sub _check_workers {
    my Gearman::WorkerSpawner $self = shift;

    # reap slots from dead kids
    while ((my $pid = waitpid(-1, WNOHANG)) > 0) {
        my $open_slot = delete $kids{$pid};
        if (defined $open_slot) {
            push @open_slots, $open_slot;
        }
        else {
            warn "dead child $pid didn't own a slot" unless defined $open_slot;
        }
    }

    # refill lowest slots first
    @open_slots = sort {$a->[SLOT_NUM]<=>$b->[SLOT_NUM]} @open_slots;

    # check if we're deficient in the kid quota. this handles both initial population and respawning
    while (scalar keys %kids < $num_workers) { # should be equivalent to 'while (@open_slots)'
        my $slot = shift @open_slots;
        if (defined $slot) {
            my $pid = $self->_spawn_worker($slot);
            $kids{$pid} = $slot;
        }
        else {
            carp "no open slot" unless defined $slot; # this should never happen
        }
    }
}

sub _serialize {
    return join '', unpack 'h*', nfreeze shift;
}

sub _deserialize {
    return thaw pack 'h*', shift;
}

sub _spawn_worker {
    my Gearman::WorkerSpawner $self = shift;
    my $slot = shift;

    my $params = $slot->[SLOT_PARAMS];

    my $executer = sub {
        local $ENV{EXIT_WITH_PARENT} = 1; # so that worker will exit when gearmand does
        exec
            $self->{perl},
            $params->{script},
            $params->{class},
            $slot->[SLOT_NUM],
            $slot->[SLOT_ID],
            _serialize($params->{worker_args});
    };

    if ($gearmand_spec eq 'inproc') {
        # Gearman::Server does the fork for us in order to connect the socketpair
        return gearman_server()->start_worker($executer);
    }
    else {
        # pass location of gearmand to kid: this is picked out of ENV by _run
        local $ENV{EXTERNAL_GEARMAND} = join ',', gearman_server();
        my $pid = fork;
        $executer->() if !$pid;
        return $pid;
    }
}

=item Gearman::WorkerSpawner->_run('My::WorkerClass', @ARGV)

Loads the given L<Gearman::Worker> subclass, then parses additional arguments
as specified by the return value of the worker class' C<options()> class method
via L<Getopt::Long>. These options are passed to the worker object's
constructor and the C<work> method of the worker object is called repeatedly
until either SIG_INT is received or the ppid changes (parent went away). Unless
the ALLOW_ORPHANS environmental variable is set, workers will refuse to start
if their initial ppid is 1 (init). This prevents orphans from surviving a
parent which dies immediately after forking.

This class method is automatically executed if Gearman/WorkerSpawner.pm has no
C<caller()>, i.e. if it is run as a script rather than loaded as a module. This
should probably only be done by other internal methods of this package.

=back

=cut

sub _run {
    my $spawner_class     = shift;
    my $worker_class      = shift;
    my $slot_num          = shift;
    my $worker_id         = shift;
    my $serialized_params = shift;

    my $parent_pid = getppid();
    die "I can't be owned by init(8)" if $parent_pid == 1 && !$ENV{ALLOW_ORPHANS};

    if (!$ENV{EXTERNAL_GEARMAND} && $Gearman::Server::VERSION <= 1.09) {
        die "Won't use inproc gearmand with buggy Gearman::Server $Gearman::Server::VERSION";
    }

    die "no worker class provided" unless $worker_class;

    unless (eval "use $worker_class; 1") {
        die "failed to load worker class $worker_class: $@";
    }

    my $worker = $worker_class->new($slot_num, _deserialize($serialized_params));

    die "failed to create $worker_class object" unless $worker;

    $worker->job_servers(split /,/, $ENV{EXTERNAL_GEARMAND}) if $ENV{EXTERNAL_GEARMAND};

    $0 = sprintf "%s #%d", $worker_class, $slot_num;

    if ($worker->can('register_function')) {
        # each worker gets a unique function so we can ping it
        $worker->register_function(_ping_name($worker_id) => sub { return 1 });
    }

    my $done = 0;
    $SIG{INT} = sub { $done = 1 };
    while (!$done) {
        eval {
            $worker->work(stop_if => sub {1});
        };
        $@ && warn "$worker_class [$$] failed: $@";

        if ($worker->can('post_work')) {
            $worker->post_work;
        }

        if ($ENV{EXIT_WITH_PARENT} && getppid() != $parent_pid) {
            # bail if parent went away
            $done = 1;
        }
    }
    exit;
}

# we're being called as a script, not a module, presumably from exec in _spawn_worker.
__PACKAGE__->_run(@ARGV) unless caller();

1;

__END__

=head1 SEE ALSO

L<Gearman::Server>

L<Gearman::Worker>

L<Gearman::Task>

L<Gearman::Client::Async>

L<Getopt::Long>

brian d foy's modulino article: L<http://www.ddj.com/dept/debug/184416165>

=head1 AUTHOR

Adam Thomason, E<lt>athomason@sixapart.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2007 by Six Apart, E<lt>cpan@sixapart.comE<gt>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.6 or,
at your option, any later version of Perl 5 you may have available.

=cut
