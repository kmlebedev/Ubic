package Ubic;

use strict;
use warnings;

use Yandex::Version '{{DEBIAN_VERSION}}';

=head1 NAME

Ubic - frontend to all ubic services

=head1 SYNOPSIS

    Ubic->start("yandex-something");

    Ubic->stop("yandex-something");

    $status = Ubic->status("yandex-something");

=head1 DESCRIPTION

Ubic allows you to implement safe services which will be monitored and checked automatically.

This module is a main frontend to ubic services.

Further directions:

if you want to manage ubic services from perl scripts, read this POD;

if you want to use ubic from command line, see L<ubic(1)> and L<Ubic::Cmd>.

if you want to write your own service, see L<Ubic::Service> and other C<Ubic::Service::*> modules. Check out L<Ubic::Run> for integration with SysV init script system too.

=cut

use POSIX qw();
use Ubic::Result qw(result);
use Ubic::Multiservice::Dir;
use Ubic::AccessGuard;
use Params::Validate qw(:all);
use Carp;
use IO::Handle;
use Storable qw(freeze thaw);
use Yandex::Persistent;
use Yandex::Lockf;
use Yandex::X qw(xopen xclose xfork);
use Scalar::Util qw(blessed);

our $SINGLETON;

# singleton constructor
sub _obj {
    my ($param) = validate_pos(@_, 1);
    if (blessed($param)) {
        return $param;
    }
    if ($param eq 'Ubic') {
        # method called as a class method => singleton
        $SINGLETON ||= Ubic->new({});
        return $SINGLETON;
    }
    die "Unknown argument '$param'";
}

=head1 CONSTRUCTOR

=over

=item B<< Ubic->new({ ... }) >>

All methods in this package can be invoked as class methods, but sometimes you may need to override some status dirs. In this case you should construct your own instance.

Constructor options (all of them are optional):

=over

=item I<watchdog_dir>

Dir with persistent services' watchdogs.

=item I<service_dir>

Name of dir with service descriptions (which will be used to construct root Ubic::Multiservice::Dir object)

=item I<lock_dir>

Dir with services' locks.

=back

=cut
sub new {
    my $class = shift;
    my $ubic_dir = $ENV{UBIC_DIR} || '/var/lib/ubic';
    my $self = validate(@_, {
        service_dir =>  { type => SCALAR, default => $ENV{UBIC_SERVICE_DIR} || "/etc/ubic/service" },
        watchdog_dir => { type => SCALAR, default => $ENV{UBIC_WATCHDOG_DIR} || "$ubic_dir/watchdog" },
        lock_dir =>  { type => SCALAR, default => $ENV{UBIC_LOCK_DIR} || "$ubic_dir/lock" },
        tmp_dir =>  { type => SCALAR, default => $ENV{UBIC_TMP_DIR} || "$ubic_dir/tmp" },
    });
    $self->{locks} = {};
    $self->{root} = Ubic::Multiservice::Dir->new($self->{service_dir});
    return bless $self => $class;
}

=back

=head1 LSB METHODS

See L<http://refspecs.freestandards.org/LSB_3.1.0/LSB-Core-generic/LSB-Core-generic/iniscrptact.html> for init-script method specifications.

Following functions are trying to conform, except that all dashes in method names are replaced with underscores.

Unlike C<Ubic::Service> methods, these methods are guaranteed to return blessed versions of result, i.e. C<Ubic::Result::Class> objects.

=over

=item B<start($name)>

Start service.

=cut
sub start($$) {
    my $self = _obj(shift);
    my ($name) = validate_pos(@_, 1);
    my $lock = $self->lock($name);

    $self->enable($name);
    my $result = $self->do_cmd($name, 'start');
    if ($result->status eq 'running') {
        $self->set_cached_status($name, 'running');
    }
    return $result;
}

=item B<stop($name)>

Stop service.

=cut
sub stop($$) {
    my $self = _obj(shift);
    my ($name) = validate_pos(@_, 1);
    my $lock = $self->lock($name);

    $self->disable($name);
    my $result = $self->do_cmd($name, 'stop');
    # we can't save result in watchdog file - it doesn't exist when service is disabled...
    return $result;
}

=item B<restart($name)>

Restart service; start it if it's not running.

=cut
sub restart($$) {
    my $self = _obj(shift);
    my ($name) = validate_pos(@_, 1);
    my $lock = $self->lock($name);

    $self->enable($name);
    my $result = $self->do_cmd($name, 'stop');
    $result = $self->do_cmd($name, 'start');

    if ($result->status eq 'running') {
        $self->set_cached_status($name, 'running');
    }
    return result('restarted'); # FIXME - should return original status
}

=item B<try_restart($name)>

Restart service if it is enabled.

=cut
sub try_restart($$) {
    my $self = _obj(shift);
    my ($name) = validate_pos(@_, 1);
    my $lock = $self->lock($name);

    unless ($self->is_enabled($name)) {
        return result('down');
    }
    $self->do_cmd($name, 'stop');
    $self->do_cmd($name, 'start');
    return result('restarted');
}

=item B<reload($name)>

Reloads service if reloading is implemented; throw exception otherwise.

=cut
sub reload($$) {
    my $self = _obj(shift);
    my ($name) = validate_pos(@_, 1);
    my $lock = $self->lock($name);

    unless ($self->is_enabled($name)) {
        return result('down');
    }

    # if reload isn't implemented, do nothing
    # TODO - would it be better to execute reload as force-reload always? but it would be incompatible with LSB specification...
    my $result = $self->do_cmd($name, 'reload');
    unless ($result->action eq 'restarted') {
        die result('unknown', 'reload not implemented');
    }
    return $result;
}

=item B<force_reload($name)>

Reloads service if reloading is implemented, otherwise restarts it.

Does nothing if service is disabled.

=cut
sub force_reload($$) {
    my $self = _obj(shift);
    my ($name) = validate_pos(@_, 1);
    my $lock = $self->lock($name);

    unless ($self->is_enabled($name)) {
        return result('down');
    }

    my $result = $self->do_cmd($name, 'reload');
    return $result if $result->action eq 'restarted';

    $self->try_restart($name);
}

=item B<status($name)>

Get service status.

=cut
sub status($$) {
    my $self = _obj(shift);
    my ($name) = validate_pos(@_, 1);
    my $lock = $self->lock($name);

    return $self->do_cmd($name, 'status');
}

=back

=head1 OTHER METHODS

=over

=item B<enable($name)>

Enable service.

Enabled service means that service *should* be running. It will be checked by watchdog and marked as broken if it's enabled but not running.

=cut
sub enable($$) {
    my $self = _obj(shift);
    my ($name) = validate_pos(@_, 1);
    my $lock = $self->lock($name);
    my $guard = Ubic::AccessGuard->new($self->service($name));

    my $watchdog = $self->watchdog($name);
    $watchdog->{status} = 'unknown';
    $watchdog->commit;
    return result('unknown');
}

=item B<is_enabled($name)>

Returns true value if service is enabled, false otherwise.

=cut
sub is_enabled($$) {
    my $self = _obj(shift);
    my ($name) = validate_pos(@_, 1);

    die "Service '$name' not found" unless $self->{root}->has_service($name);
    return (-e $self->watchdog_file($name)); # watchdog presence means service is running or should be running
}

=item B<disable($name)>

Disable service.

Disabled service means that service is ignored by ubic. It's state will no longer be checked by watchdog, and pings will answer that service is not running, even if it's not true.

=cut
sub disable($$) {
    my $self = _obj(shift);
    my ($name) = validate_pos(@_, 1);
    my $lock = $self->lock($name);
    my $guard = Ubic::AccessGuard->new($self->service($name));

    if ($self->is_enabled($name)) {
        unlink $self->watchdog_file($name) or die "Can't unlink '".$self->watchdog_file($name)."'";
    }
}


=item B<cached_status($name)>

Get cached status of enabled service.

Unlike other methods, it doesn't require user to be root.

=cut
sub cached_status($$) {
    my ($self) = _obj(shift);
    my ($name) = validate_pos(@_, 1);

    unless ($self->is_enabled($name)) {
        return result('disabled');
    }
    return result($self->watchdog_ro($name)->{status});
}

=item B<do_custom_command($name, $command)>

=cut
sub do_custom_command($$) {
    my ($self) = _obj(shift);
    my ($name, $command) = validate_pos(@_, 1, 1);

    # TODO - do all custom commands require locks?
    # they can be distinguished in future by some custom_commands_ext method which will provide hash { command => properties }, i think...
    my $lock = $self->lock($name);

    # TODO - check custom_command presence by custom_commands() method first?
    $self->do_sub(sub {
        $self->service($name)->do_custom_command($command); # can custom commands require custom arguments?
    });
}

=item B<service($name)>

Get service _object by name.

=cut
sub service($$) {
    my $self = _obj(shift);
    my ($name) = validate_pos(@_, { type => SCALAR, regex => qr{^[\w-]+(?:\.[\w-]+)*$} }); # this guarantees that : will be unambiguous separator in watchdog filename
    return $self->{root}->service($name);
}

=item B<services()>

Get list of all services.

=cut
sub services($) {
    my $self = _obj(shift);
    return $self->{root}->services();
}

=item B<service_names()>

Get list of names of all services.

=cut
sub service_names($) {
    my $self = _obj(shift);
    return $self->{root}->service_names();
}

=item B<root_service()>

Get root service.

Root service doesn't have a name and returns all top-level services with C<services()> method. You can use it to traverse all services' tree.

=cut
sub root_service($) {
    my $self = _obj(shift);
    return $self->{root};
}

=item B<compl_services($line)>

Return list of autocompletion variants for given service prefix.

=cut
sub compl_services($$) {
    my $self = _obj(shift);
    my $line = shift;
    my @parts = split /\./, $line;
    if (@parts == 0) {
        return $self->service_names;
    }
    my $node = $self->root_service;
    while (@parts > 1) {
        my $part = shift @parts;
        return unless $node->has_service($part); # no such service
        $node = $node->service($part);
    }
    my @variants = $node->service_names;
    return grep { $_ =~ m{^\Q$line\E} } @variants;
}

=item B<set_cached_status($name, $status)>

Write new status into service's watchdog status file.

=cut
sub set_cached_status($$$) {
    my $self = _obj(shift);
    my ($name, $status) = validate_pos(@_, 1, 1);
    my $guard = Ubic::AccessGuard->new($self->service($name));

    if (blessed $status) {
        croak "Wrong status param '$status'" unless $status->isa('Ubic::Result::Class');
        $status = $status->status;
    }
    my $lock = $self->lock($name);

    my $watchdog = $self->watchdog($name);
    $watchdog->{status} = $status;
    $watchdog->commit;
}

=item B<< set_ubic_dir($dir) >>

Create and set ubic dir.

Ubic dir is a directory with service statuses and locks. By default, ubic dir is C</var/lib/ubic> and it is packaged in ubic distribution, but in tests you may want to change it.

These settings will be propagated into subprocesses using environment, so you can write in comments following code:

    Ubic->set_ubic_dir('tfiles/ubic');
    Ubic->set_service_dir('etc/ubic/service');
    xsystem('ubic start some_service');
    xsystem('ubic stop some_service');

=cut
sub set_ubic_dir($$) {
    my $self = _obj(shift);
    my ($dir) = validate_pos(@_, 1);
    unless (-d $dir) {
        mkdir $dir or die "mkdir $dir failed: $!";
    }

    # TODO - chmod 777, chmod +t?
    # TODO - call this method from postinst too?
    mkdir "$dir/lock" or die "mkdir $dir/lock failed: $!" unless -d "$dir/lock";
    mkdir "$dir/watchdog" or die "mkdir $dir/watchdog failed: $!" unless -d "$dir/watchdog";
    mkdir "$dir/tmp" or die "mkdir $dir/tmp failed: $!" unless -d "$dir/tmp";
    mkdir "$dir/pid" or die "mkdir $dir/pid failed: $!" unless -d "$dir/pid"; # Ubic don't use /pid/, but Ubic::Daemon does

    $self->{lock_dir} = "$dir/lock"; $ENV{UBIC_LOCK_DIR} = $self->{lock_dir};
    $self->{watchdog_dir} = "$dir/watchdog"; $ENV{UBIC_WATCHDOG_DIR} = $self->{watchdog_dir};
    $self->{tmp_dir} = "$dir/tmp"; $ENV{UBIC_TMP_DIR} = $self->{tmp_dir};
    $ENV{UBIC_DAEMON_PID_DIR} = "$dir/pid";
}

=item B<< set_service_dir($dir) >>

Set ubic services dir.

=cut
sub set_service_dir($$) {
    my $self = _obj(shift);
    my ($dir) = validate_pos(@_, 1);
    $self->{service_dir} = $dir;
    $ENV{UBIC_SERVICE_DIR} = $dir;
    $self->{root} = Ubic::Multiservice::Dir->new($self->{service_dir}); # FIXME - copy-paste from constructor!
}

=back

=head1 INTERNAL METHODS

You don't need to call these, usually.

=over

=item B<watchdog_file($name)>

Get watchdog file name by service's name.

=cut
sub watchdog_file($$) {
    my $self = _obj(shift);
    my ($name) = validate_pos(@_, { type => SCALAR, regex => qr{^[\w-]+(?:\.[\w-]+)*$} });
    return "$self->{watchdog_dir}/".$name;
}

=item B<watchdog($name)>

Get watchdog persistent object by service's name.

=cut
sub watchdog($$) {
    my $self = _obj(shift);
    my ($name) = validate_pos(@_, 1);
    return Yandex::Persistent->new($self->watchdog_file($name));
}

=item B<watchdog_ro($name)>

Get readonly, nonlocked watchdog persistent object by service's name.

=cut
sub watchdog_ro($$) {
    my $self = _obj(shift);
    my ($name) = validate_pos(@_, 1);
    return Yandex::Persistent->new($self->watchdog_file($name), {lock => 0}); # lock => 0 should allow to construct persistent even without writing rights on it
}

=item B<lock($name)>

Acquire lock object for given service.

You can lock one object twice from the same process, but not from different processes.

=cut
sub lock($$) {
    my ($self) = _obj(shift);
    my ($name) = validate_pos(@_, { type => SCALAR, regex => qr{^[\w-]+(?:\.[\w-]+)*$} });
    unless ($self->{locks}{$name}) {
        $self->{locks}{$name} = Ubic::Lock->new($name, $self);
    }
    return $self->{locks}{$name};
}

{
    package Ubic::Lock;
    use strict;
    use warnings;
    use Yandex::Lockf;
    use Scalar::Util qw(weaken);
    sub new {
        my ($class, $name, $ubic) = @_;

        my $lock = do {
            my $guard = Ubic::AccessGuard->new($ubic->service($name));
            lockf($ubic->{lock_dir}."/".$name);
        };

        my $ubic_ref = \$ubic;
        my $self = bless { name => $name, ubic_ref => $ubic_ref, lock => $lock } => $class;
        weaken($self->{ubic_ref});
        return $self;
    }
    sub DESTROY {
        my $self = shift;
        my $ubic = ${$self->{ubic_ref}};
        $ubic->_free_lock($self->{name});
    }
}

sub _free_lock {
    my $self = _obj(shift);
    my ($name) = validate_pos(@_, { type => SCALAR, regex => qr{^[\w-]+(?:\.[\w-]+)*$} });
    delete $self->{locks}{$name};
}

=item B<< do_sub($code) >>

Run any code and wrap result into C<Ubic::Result::Class> object.

=cut
sub do_sub($$) {
    my ($self, $code) = @_;
    my $result = eval {
        $code->();
    }; if ($@) {
        die result($@);
    }
    return result($result);
}

=item B<< do_cmd($name, $cmd) >>

Run C<$cmd> method from service C<$name> and wrap any result or exception into C<Ubic::Result::Class> object.

=cut
sub do_cmd($$$) {
    my ($self, $name, $cmd) = @_;
    $self->do_sub(sub {
        my $service = $self->service($name);
        my $user = $service->user;
        my $service_uid = getpwnam($user);
        unless (defined $service_uid) {
            die "user $user not found";
        }
        if ($service_uid == $> and $service_uid == $<) {
            $service->$cmd();
        }
        else {
            # locking all service operations inside fork with correct real and effective uids
            # setting just effective uid is not enough, and tainted mode requires too careful coding
            $self->forked_call(sub {
                POSIX::setuid($service_uid);
                $service->$cmd();
            });
        }
    });
}

=item B<< forked_call($callback) >>

Run C<$callback> inside fork and return its return value.

Interaction happens through temporary file in C<$ubic->{tmp_dir}> dir.

=cut
sub forked_call {
    my ($self, $callback) = @_;
    my $tmp_file = $self->{tmp_dir}."/".time.".".rand(1000000);
    my $child;
    unless ($child = xfork) {
        my $result = eval {
            $callback->();
        };
        if ($@) {
            $result = { error => $@ };
        }
        else {
            $result = { ok => $result };
        }
        eval {
            my $fh = xopen(">", "$tmp_file.tmp");
            print {$fh} freeze($result);
            xclose($fh);
            STDOUT->flush;
            STDERR->flush;
            rename "$tmp_file.tmp", $tmp_file;
            POSIX::_exit(0); # don't allow to lock to be released - this process was forked from unknown environment, don't want to run unknown destructors
        }; if ($@) {
            # probably tmp_file is not writtable
            warn $@;
            POSIX::_exit(1);
        }
    }
    waitpid($child, 0);
    unless (-e $tmp_file) {
        die "temp file not found after fork (probably failed write to $self->{tmp_dir})";
    }
    my $fh = xopen('<', $tmp_file);
    my $content = do { local $/; <$fh>; };
    xclose($fh);
    unlink $tmp_file;
    my $result = thaw($content);
    if ($result->{error}) {
        die $result->{error};
    }
    else {
        return $result->{ok};
    }
}

=back

=head1 AUTHOR

Vyacheslav Matjukhin <mmcleric@yandex-team.ru>

=cut

1;

