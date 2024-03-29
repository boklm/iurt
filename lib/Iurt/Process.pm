package Iurt::Process;

use strict;
use base qw(Exporter);
use MDK::Common;
use Filesys::Df qw(df);
use Iurt::Mail qw(sendmail);
use Iurt::Config qw(dump_cache_par);
use Iurt::Util qw(plog);
use POSIX ":sys_wait_h";
use Sys::Load qw(getload);

our @EXPORT = qw(
    kill_for_good
    clean_process
    check_pid
    perform_command
    sudo
);

my $sudo = '/usr/bin/sudo';

=head2 config_usage($program_name, $run)

Check that there is no other program running and create a pidfile lock
I<$run> current running options
Return true.

=cut

# CM: this actually doesn't offer race-free locking, a better system
#     should be designed

sub check_pid {
    my ($run) = @_;

    my $pidfile = "$run->{pidfile_home}/$run->{pidfile}";

    # Squash double slashes for cosmetics
    $pidfile =~ s!/+!/!g;

    plog('DEBUG', "check pidfile: $pidfile");

    if (-f $pidfile)  {
	my (@stat) = stat $pidfile;

	my $pid = cat_($pidfile);

	if (!$pid) {
	    plog('ERROR', "ERROR: invalid pidfile ($pid), should be <pid>");
	    unlink $pidfile;
	}

	if ($pid && getpgrp $pid != -1) {
	    my $time = $stat[9];
	    my $state = `ps h -o state $pid`;
	    chomp $state;

	    if ($time < time()-7200 || $state eq 'Z') {
		my $i;

		plog('WARN', "another instance [$pid] is too old, killing it");

		while ($i < 5 && getpgrp $pid != -1) {
		    kill_for_good($pid);
		    $i++;
		    sleep 1;
		}
	    } else  {
		plog('WARN', "another instance [$pid] is already running for ",
				time()-$time, " seconds");
		exit();
	    }
	} else {
	    plog('WARN', "cleaning stale lockfile");
	    unlink $pidfile;
	}
    }

    output($pidfile, $$);

    $pidfile;
}


sub fork_to_monitor {
    my ($run, $config, $logfile, %opt) = @_;
    my $parent_pid = $$;
    my $pid = fork();
    #close STDIN; close STDERR;close STDOUT;
    my $tot_time;
    if (!$pid) {
	plog('DEBUG', "Forking to monitor log size");
	$run->{main} = 0;
	# So that we don't get killed by alarm set by parent:
	local $SIG{ALRM} = sub { exit() };
	$tot_time += sleep 30;
	my $size_limit = $config->{log_size_limit};
	$size_limit =~ s/k/000/i;
	$size_limit =~ s/M/000000/i;
	$size_limit =~ s/G/000000000/i;
	while ($tot_time < $opt{timeout}) {
	    my (@stat) = stat $logfile;
	    if ($stat[7] > $size_limit) {
		# FIXME: we left runaway processes (eg: urpmi)
		plog('ERROR', "Killing current command because of log size exceeding limit ($stat[7] > $config->{log_size_limit})");
		kill 14, "-$parent_pid";
		exit();
	    }
	    if ($stat[9] + $opt{stalled_timeout} < time()) {
		# If nothing was written to the logfile for more than stalled_timeout, check if the system seems busy
		if ((getload())[1] < 0.5) {
		    plog('ERROR', "Killing current command because it seems blocked");
		    kill 14, "-$parent_pid";
		    exit();
		}
	    }

	    my $df = df $opt{log};
	    if ($df->{per} >= 99) {
		# FIXME: we left runaway processes (eg: urpmi)
		plog('ERROR', "Killing current command because running out of disk space at $opt{log} (only $df->{bavail}KB left)");
		kill 14, "-$parent_pid";
		exit();
	    }
	    $tot_time += sleep 30;
	}
	exit();
    } else {
	$pid;
    }
}

sub handle_command_error {
    my ($run, $config, $cache, $log_msg, $comment, $fulloutput, %opt) = @_;
    plog('ERROR', $log_msg);

    if ($opt{log} && $config->{log_url}) {
	$comment = qq(See $config->{log_url}/$run->{distro_tag}/$run->{my_arch}/$run->{media}/log/$opt{srpm}/\n\n$comment);
    }

    my $out;
    if (length $fulloutput < 10000) {
	$out = $fulloutput;
    } else { 
	$out = "Message too big, see http link for details\n";
    }

    if ($opt{mail} && $config->{sendmail} && !$config->{no_mail}{$opt{mail}}) {
	if (! ($cache->{warning}{$opt{hash}}{$opt{mail}} % $opt{freq})) {
	    my $cc = join ',', grep { !$config->{no_mail}{$_} } split ',', $opt{cc};
	    sendmail($opt{mail}, $cc,  $opt{error} , "$comment\n$out", "Iurt the rebuild bot <$config->{admin}>", $opt{debug_mail}, $config);
	} elsif ($config->{admin}) {
	    sendmail($config->{admin}, '' , $opt{error}, "$comment\n$out", "Iurt the rebuild bot <$config->{admin}>", $opt{debug_mail}, $config);
	}
    }
    $cache->{warning}{$opt{hash}}{$opt{mail}}++;
    plog('FAIL', $comment);
    plog('INFO', "--------------- Command failed, full output follows ---------------");
    plog('INFO', $fulloutput);
    plog('INFO', "--------------- end of command output ---------------");

    if ($opt{die}) {
	dump_cache_par($run);
	die "FATAL: $opt{error}.";
    }
}

sub handle_wait_regexp {
    my ($run, $config, $comment, $output, %opt) = @_;
    my $inc;
    foreach my $wr (keys %{$opt{wait_regexp}}) {
	if ($output =~ /$wr/m) {
	    if (ref $opt{wait_regexp}{$wr}) {
		$inc = $opt{wait_regexp}{$wr}(\%opt, $output);
	    }
	    plog('ERROR', "ERROR: $wr !");

	    if ($opt{wait_mail}) {
		sendmail($config->{admin}, '' ,
			 "$opt{hash} on $run->{my_arch} for $run->{media}: could not proceed",
			 "$wr\n\n$comment\n$output",
			 "Iurt the rebuild bot <$config->{admin}>",
			 $opt{debug_mail}, $config);
	    }
	}
    }
    $inc;
}

sub generate_comment {
    my ($run, $config, $output, $command, $comment, $pipe, $kill, %opt) = @_;
    if ($kill && $opt{type} ne 'shell') {
	$comment = "Command killed after $opt{timeout}s: $command\n";
	my ($cmd_to_kill) = $command =~ /sudo(?: chroot \S+)? (.*)/;
	clean_process($cmd_to_kill);
    } elsif ($pipe) {
	$comment = "Command received SIGPIPE: $command\n";
	sendmail($config->{admin}, '' ,
		 "$opt{hash} on $run->{my_arch} for $run->{media}: broken pipe",
		 "$comment\n$output", "Iurt the build bot <$config->{admin}>",
		 $opt{debug_mail}, $config);
    } else {
	if ($opt{type} eq 'shell') {
	    $comment = "Command failed: $command\n";
	} else {
	    $comment = "Command failed: $opt{type}\n";
	}
    }
}

=head2 perform_command($command, $run, $config, $cache,  %opt)

Run a command and check various running parameters such as log size, timeout...
I<$command> the command to run
I<$run> current running options
I<$config> the configuration
I<$cache> cached values
I<%opt> the options for the command run
Return true.

=cut

sub perform_command {
    my ($command, $run, $config, $cache, %opt) = @_;

    $opt{timeout} ||= 300;
    $opt{freq} ||= 24;
    $opt{type} ||= 'shell';

    plog('DEBUG', "Using timeout of $opt{timeout} seconds.");

    if ($opt{use_iurt_root_command}) {
        my ($binary, $args) = $command =~ /^(\S*)(.*)$/;
        $command = "$sudo $config->{iurt_root_command} --$binary$args";
    }

    my ($output, $fulloutput, $comment);
    my ($kill, $pipe);

    if ($opt{debug}) {
	if ($opt{type} eq 'perl') {
	    print "Would run perl command with timeout = $opt{timeout}\n";
	} else {
	    print "Would run $command with timeout = $opt{timeout}\n";
	}
	return 1;
    }

    local $SIG{PIPE} = sub { print "Broken pipe!\n"; $pipe = 1 };

    my $retry = $opt{retry} || 1;
    my $call_ret = 1;
    my ($err, $try);
    my $logfile = "$opt{log}/$opt{logname}.$run->{run}.log";
    my $max_retry = max($config->{max_command_retry}, $retry);

    while ($retry) {
	$try++;
	$logfile = "$opt{log}/$opt{logname}-$try.$run->{run}.log" if $opt{retry} > 1;
	my $pid = $opt{log} ? fork_to_monitor($run, $config, $logfile, %opt) : 0;

	eval {
	    # handle timeout:
	    local $SIG{ALRM} = sub {
		print "Timeout!\n";
		$kill = 1;
		die "alarm\n";  # NB: \n required
	    };

	    alarm $opt{timeout};

	    # actually execute it:
	    if ($opt{type} eq 'perl') {
		plog('DEBUG', "perl command");
		$command->[0](@{$command->[1]});
	    } else {
		plog('DEBUG', $command);
		if ($opt{log}) {
		    #$output = `$command 2>&1 2>&1 | tee $opt{log}/$opt{hash}.$run.log`;
		    system("$command &> $logfile");
		} else {
		    $output = `$command 2>&1`;
		}
	    }
	    # completed before timeout, disable it:
	    alarm 0;
	};

	# external program exit code
	$err = $?;
	# perl exception:
	my $perl_err = $@;

	# <mrl> Log it before any changes on it.
	plog('DEBUG', "Command exited with $err.");

	# some errors might be OK:
	$err = 0 if any { $_ == $err } @{$opt{error_ok}};

	# kill pid watching log file size
	kill_for_good($pid) if $pid;

	if ($perl_err) {	# timed out
	    # propagate unexpected errors
	    die "FATAL: unexpected signal ($perl_err)" unless $perl_err eq "alarm\n";
	}

	# Keep the run first on the harddrive so that one can check the
	# command status tailing it
	$output = cat_($logfile) if $opt{log};

	$fulloutput .= $output;
	if (ref $opt{callback}) {
	    $call_ret = $opt{callback}(\%opt, $output);
	    $call_ret == -1 and return 1;
	    $call_ret == -2 and return 0;
	}

	$comment = generate_comment($run, $config, $output, $command, $comment, $pipe, $kill, %opt);

	# Maybe this has to be put before all the commands altering the
	# $output var

	my $inc;
	if ($opt{wait_regexp}) {
	    $inc = handle_wait_regexp($run, $config, $comment, $output, %opt);
	}

	if ($inc && $try < $max_retry) {
	    $retry += $inc;
	} elsif ($call_ret && !$kill && !$err && !$opt{error_regexp} || $fulloutput !~ /$opt{error_regexp}/) {
	    $retry = 0;
	} else {
	    $retry--;
	}
    }

    if (!$call_ret || $kill || $err || $opt{error_regexp} && $fulloutput =~ /$opt{error_regexp}/) {
	my $msg = "ERROR: call_ret=$call_ret kill=$kill err=$err ($opt{error_regexp})";
	handle_command_error($run, $config, $cache, $msg, $comment, $fulloutput, %opt);
        return 0;
    }
    1;
}

sub clean_process {
    my ($match) = @_;
    return clean($match, "pgrep -u root -f", "$sudo pkill -9 -u root -f");
}

sub clean {
    my ($var, $cmd, $kill_cmd) = @_;

    plog('DEBUG', "clean command $var");
    $var or die "FATAL: no command given\n.";

    my $ps;
    my $i;

    while ($ps = `$cmd "$var"`) {
	plog('WARN', "Killing: $kill_cmd $var");
	system(qq($kill_cmd "$var" &>/dev/null));
	sleep 1;
	$ps =~ s/\n/,/g;
	plog('WARN', "Trying to remove previous blocked processes for $var ($ps)");
	waitpid(-1, POSIX::WNOHANG);
	return 0 if $i++ > 10;
    }
    1;
}

sub kill_for_good {
    my ($pid) = @_;

    # try SIGALARM first:
    kill 14, $pid;
    sleep 1;
    waitpid(-1, POSIX::WNOHANG);
    
    return if getpgrp $pid == -1;

    # try to kill it gently then:
    kill 15, $pid;
    sleep 1;
    waitpid(-1, POSIX::WNOHANG);

    return if getpgrp $pid  == -1;

    # try harder to kill it if it hasn't cooperate:
    print STDERR "WARNING: have to kill -9 pid $pid\n";
    kill 9, $pid;
    sleep 1;
    waitpid(-1, POSIX::WNOHANG);
}

sub sudo {
    my ($config, @arg) = @_;

    #plog("Running $config->{iurt_root_command} @arg");

    -x $config->{iurt_root_command}
	or die "FATAL: $config->{iurt_root_command} command not found";

    !system($sudo, $config->{iurt_root_command}, @arg);
}

1
