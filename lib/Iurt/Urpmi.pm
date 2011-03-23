package Iurt::Urpmi;

use strict;
use RPM4::Header;
use File::Basename;
use File::NCopy qw(copy);
use MDV::Distribconf::Build;
use Iurt::Chroot qw(add_local_user create_temp_chroot check_build_chroot);
use Iurt::Process qw(perform_command clean clean_process sudo);
use Iurt::Config qw(dump_cache_par get_maint get_package_prefix);
use Iurt::Util qw(plog);


sub new {
    my ($class, %opt) = @_;
    my $self = bless {
        config  => $opt{config},
        run => $opt{run},
	urpmi_options => $opt{urpmi_options},
    }, $class;
    my $config = $self->{config};
    my $run = $self->{run};

    if ($run->{chrooted_urpmi}) {
	#my ($host) = $run->{chrooted_urpmi}{rooted_media} =~ m,(?:file|http|ftp)://([^/]*),;
	#my ($_name, $_aliases, $_addrtype, $_length, @addrs) = gethostbyname($host);
        #
	#my $ip = join('.', unpack('C4', $addrs[0]));
        #
	#$ip =~ /\d+\.\d+\.\d+\.\d+/
	#	or die "FATAL: could not resolve $host ip address";
        #
	#$run->{chrooted_urpmi}{rooted_media} =~ s/$host/$ip/;
	$run->{chrooted_media} = $run->{chrooted_urpmi}{rooted_media} .
			"/$run->{distro}/$run->{my_arch}";

	# Now squash all slashes that don't follow colon
	$run->{chrooted_media} =~ s|(?<!:)/+|/|g;

	plog('DEBUG', "installation media: $run->{chrooted_media}");
    }
    $self->{use__urpmi_root} = $config->{repository} =~ m/^(http|ftp):/;
    $self->{distrib_url} = "$config->{repository}/$run->{distro}/$run->{my_arch}";

    $self;
}

sub set_command {
    my ($self, $_chroot_tmp) = @_;
    $self->{use__urpmi_root} ? &set_command__urpmi_root : &set_command__use_distrib;
}
sub set_command__urpmi_root {
    my ($self, $chroot_tmp) = @_;
    $self->{use_iurt_root_command} = 1;
    $self->{urpmi_command} = "urpmi $self->{urpmi_options} --urpmi-root $chroot_tmp";
}
sub set_command__use_distrib {
    my ($self, $chroot_tmp) = @_;
    $self->{use_iurt_root_command} = 1;
    $self->{urpmi_command} = "urpmi $self->{urpmi_options} --use-distrib $self->{distrib_url} --root $chroot_tmp";
}
sub set_command__chrooted {
    my ($self, $chroot_tmp) = @_;
    $self->{urpmi_command} = "chroot $chroot_tmp urpmi $self->{urpmi_options} ";
}

sub set_local_media {
    my ($self, $local_media) = @_;
    $self->{local_media} = $local_media;
}

sub add_to_local_media {
    my ($self, $chroot_tmp, $srpm, $luser) = @_;
    my $local_media = $self->{local_media};

    system("cp $chroot_tmp/home/$luser/rpm/RPMS/*/*.rpm $local_media &>/dev/null") and plog("ERROR: could not copy rpm files from $chroot_tmp/home/$luser/rpm/RPMS/ to $local_media ($!)");
    system("cp $chroot_tmp/home/$luser/rpm/SRPMS/$srpm $local_media &>/dev/null") and plog("ERROR: could not copy $srpm from $chroot_tmp/home/$luser/rpm/SRPMS/ to $local_media ($!)");
}

sub urpmi_command {
    my ($self, $chroot_tmp, $_luser) = @_;
    my $run = $self->{run};
    my $local_media = $self->{local_media};

    #plog(3, "urpmi_command ($chroot_tmp user $luser)");
    if ($run->{chrooted_urpmi}) { 
	$self->set_command($chroot_tmp);

# CM: commented out
#     this was causing rpm database corruption problems and the packages
#     are already installed
#
#        if (!install_packages($self, 'chroot', $chroot_tmp, $local_spool, {}, 'configure', "[ADMIN] installation of urpmi and sudo failed in the chroot $run->{my_arch}", { maintainer => $config->{admin}, check => 1 }, 'urpmi', 'sudo')) {
#	    $run->{chrooted_urpmi} = 0;
#	    return
#	}

	# Here should be added only the needed media for the given package
	#  main/release -> main/release
	#  main/testing -> main/release main/testing
	#  contrib/release -> contrib/release main/release
	#  contrib/testing -> contrib/testing contrib/release main/testing main/release
	#  non-free/release ...
	# This is now done with an option in iurt2 --chrooted-urpmi -m media1 media2 -- media_url

	if ($run->{chrooted_urpmi}{media}) {
	    foreach my $m (@{$run->{chrooted_urpmi}{media}}) {
		my $m_name = $m;
		$m_name =~ s,/,_,g;
		if (!add_media($self, $chroot_tmp, $m_name,
			"$m_name $run->{chrooted_media}/media/$m")) {
		    $run->{chrooted_urpmi} = 0;
		    plog('ERROR', "Failed to add media $m_name. Disabling chrooted_urpmi.");
		    return;
		}
	    }
	} else {
	    if (!add_media($self, $chroot_tmp, 'Main', "--distrib $run->{chrooted_media}")) {
		if (!add_media($self, $chroot_tmp, 'Main', "--wget --distrib $run->{chrooted_media}")) {
		    $run->{chrooted_urpmi} = 0;
		    plog('ERROR', "Failed to add media $run->{chrooted_media}. Disabling chrooted_urpmi.");
		    return;
		}
	    }
	}

	foreach my $m (@{$run->{additional_media}{media}}) {
	    my $name = "$run->{additional_media}{repository}_$m";
	    $name =~ s![/:]!_!g;

	    my $url;
	    if ($run->{additional_media}{repository} =~ m!^(http:|ftp:)!) {
		$url = $run->{additional_media}{repository};
	    }
	    else {
		$url = "/urpmi_medias/$run->{distro}/$m";
	    }

	    # Check if the media is not empty, as add_media will abort if it fails
	    my $DP;
	    if (!opendir($DP, "$chroot_tmp/$url")) {
		plog('ERROR', "Failed to add additional media at $url: $!");
		next;
	    }
	    my @contents = readdir $DP;
	    close($DP);
	    if (@contents <= 2) {
		# Just entries: . ..
		plog('DEBUG', "$url has no packages, skipping it.");
		next;
	    }

	    if (!add_media($self, $chroot_tmp, $name, "$name $url")) {
		plog("ERROR: Unable to add media $m");
	    }
	}

	if (-d $local_media) {
	    mkdir("$chroot_tmp/iurt_media/");
	    opendir(my $dir, $local_media);
	    my $next;
	    foreach my $f (readdir $dir) {
		$f =~ /(\.rpm|^hdlist.cz)$/ or next;
		if (!link "$local_media/$f", "$chroot_tmp/iurt_media") {
		    if (!copy "$local_media/$f", "$chroot_tmp/iurt_media") {
			plog('ERROR', "could not copy file $local_media/$f to $chroot_tmp/iurt_media");
			$next = 1;
			last;
		    }
		}
	    }
	    next if $next;
	    add_media($self, $chroot_tmp, 'iurt_group', "iurt_group file:///iurt_media") or next;
	}

	$self->set_command__chrooted($chroot_tmp);
	return 1;
    } else {
	$self->set_command($chroot_tmp);
    }
}

sub check_media_added {
    my ($chroot, $media) = @_;
    my $medias = `urpmq --urpmi-root $chroot --list-media 2>&1`;
    print "MEDIA $medias ($media)\n";
    $medias =~ /$media/m;
}

sub add_media__urpmi_root {
    my ($self, $chroot, $media) = @_;
    my $run = $self->{run};
    my $config = $self->{config};
    my $cache = $run->{cache};

    foreach my $m (@{$media || []}) {
        my $url = $self->{distrib_url} . "/media/" . $m;
        my $name = $m;
        $name =~ s![/:]!_!g;
        plog("adding media $name from $url with option --urpmi-root in chroot $chroot");
        perform_command("urpmi-addmedia -v --urpmi-root $chroot $name $url --probe-synthesis", 
		$run, $config, $cache, 
		mail => $config->{admin},
		timeout => 300, 
		use_iurt_root_command => 1,
		freq => 1,
		retry => 2,
		debug_mail => $run->{debug})
          or return;
    }

    1;
}

sub add_media {
    my ($self, $chroot, $regexp, $media) = @_;
    my $run = $self->{run};
    my $config = $self->{config};
    my $cache = $run->{cache};

    plog("add chroot media: $run->{chrooted_media}");

    if (!perform_command("chroot $chroot urpmi.addmedia $media", 
		$run, $config, $cache, 
		mail => $config->{admin},
		timeout => 300, 
		freq => 1,
		retry => 2,
		use_iurt_root_command => 1,
		debug_mail => $run->{debug})) {
	}
    if (!check_media_added($chroot, $regexp)) { 
	plog('ERR', "ERROR iurt could not add media into the chroot");
	return;
    } 
    1;
}

sub add_packages {
    my ($self, $chroot, $_user, @packages) = @_;
    my $run = $self->{run};
    my $config = $self->{config};
    my $cache = $run->{cache};
    if (!perform_command("$self->{urpmi_command} @packages", 
		$run, $config, $cache, 
		use_iurt_root_command => $self->{use_iurt_root_command},
		timeout => 300, 
		freq => 1,
		retry => 2,
		error_ok => [ 11 ],
		debug_mail => $run->{debug},
		error_regexp => 'cannot be installed',
		wait_regexp => {
		    'database locked' => sub { 
		        plog("WARNING: urpmi database locked, waiting...");
		        sleep 30; 
		        $self->{wait_limit}++; 
		        if ($self->{wait_limit} > 10) { 
			    #$self->{wait_limit} = 0;
			    # <mrl> We can't shoot such command, it's too powerfull.
			    #system(qq(sudo pkill -9 urpmi &>/dev/null));
			    return 0;
			} 
			1;
		  } },)) {
	plog("ERROR: could not install @packages inside $chroot");
	return 0;
    }
    1;
}

sub get_local_provides {
    my ($self) = @_;
    my $run = $self->{run};
    my $program_name = $run->{program_name};
    my $local_media = $self->{local_media};

    opendir(my $dir, $local_media);
    plog(1, "get local provides ($local_media)");
    require URPM;
    my $urpm = new URPM;
    foreach my $d (readdir $dir) {
	$d =~ /\.src\.rpm$/ and next;
	$d =~ /\.rpm$/ or next;
	my $id = $urpm->parse_rpm("$local_media/$d");
	my $pkg = $urpm->{depslist}[$id];
	plog(3, "$program_name: checking $d provides");
        foreach ($pkg->provides, $pkg->files) {
	    plog(3, "$program_name: adding $_ as provides of $d");
	    $run->{local_provides}{$_} = $d;
	}
    }
    1;
}

sub get_build_requires {
    my ($self, $union_id, $luser) = @_;
    my $run = $self->{run};
    my $config = $self->{config};
    my $cache = $run->{cache};

    $run->{todo_requires} = {};
    plog("get_build_requires");

    my ($u_id, $chroot_tmp) = create_temp_chroot($run, $config, $cache, $union_id, $run->{chroot_tmp}, $run->{chroot_tar}) or return;
    add_local_user($chroot_tmp, $run, $config, $luser, $run->{uid}) or return;
    $union_id = $u_id;
    
    my $urpm = new URPM;
    foreach my $p (@{$run->{todo}}) {
	my ($dir, $srpm, $s) = @$p;
	recreate_srpm($self, $run, $config, $chroot_tmp, $dir, $srpm, $run->{user}) or return;
	$s or next;
	my $id = $urpm->parse_rpm("$dir/$srpm");
	my $pkg = $urpm->{depslist}[$id];
        foreach ($pkg->requires) {
	    plog(3, "adding $_ as requires of $srpm");
	    $run->{todo_requires}{$_} = $srpm;
	}
    }
    1;
}

sub order_packages {
    my ($self, $union_id, $provides, $luser) = @_;
    my $run = $self->{run};
    my @packages = @{$run->{todo}};
    my $move;

    plog(1, "order_packages");
    get_local_provides($self) or return;
    if (!$run->{todo_requires}) {
	get_build_requires($self, $union_id, $luser) or return;
    }
    my %visit;
    my %status;
    do { 
	$move = 0;
	foreach my $p (@packages) {
	    my ($_dir, $rpm, $status) = @$p;
	    defined $status{$rpm} && $status{$rpm} == 0 and next;
	    plog("checking packages $rpm");
	    foreach my $r (@{$run->{todo_requires}{$rpm}}) {
		plog("checking requires $r");
		if (!$run->{local_provides}{$r}) { 
		    if ($provides->{$r}) {
			$status = 1;
		    } else {
			$status = 0;
		    }
		} elsif ($visit{$rpm}{$r}) {
		    # to evit loops
		    $status = 0;
		} elsif ($run->{done}{$rpm} && $run->{done}{$provides->{$r}}) {
		    if ($run->{done}{$rpm} < $run->{done}{$provides->{$r}}) {
			$move = 1;
			$status = $status{$provides->{$r}} + 1;
		    } else {
			$status = 0;
		    }
		} elsif ($status < $status{$provides->{$r}}) {
		    $move = 1;
		    $status = $status{$provides->{$r}} + 1;
		}
		$visit{$rpm}{$r} = 1;
	    }
	    $status{$rpm} = $status;
	    $p->[2] = $status;
	}
    } while $move;    
    $run->{todo} = [ sort { $a->[2] <=> $b->[2] } @packages ];
    if ($run->{verbose}) {
	foreach (@packages) {
	    plog("order_packages $_->[1]");
	}
    }
    @packages;
}
	
sub wait_urpmi { 
    my ($self) = @_;
    my $run = $self->{run};

    plog("WARNING: urpmi database locked, waiting...") if $run->{debug};
    sleep 30; 
    $self->{wait_limit}++; 
    if ($self->{wait_limit} > 8) {
	#$self->{wait_limit} = 0;
	# <mrl> We can't shoot such command, it's too powerfull.
	#system(qq(sudo pkill -9 urpmi &>/dev/null));
	return 0;
    } 
}

sub install_packages_old {
    my ($self, $local_spool, $srpm, $log, $error, @packages) = @_;
    my $run = $self->{run};
    my $config = $self->{config};
    my $cache = $run->{cache};
    my $log_spool = "$local_spool/log/$srpm/";
    -d $log_spool or mkdir $log_spool;
    if (!perform_command("$self->{urpmi_command} @packages", 
		$run, $config, $cache, 
		#	mail => $maintainer, 
		use_iurt_root_command => $self->{use_iurt_root_command},
		error => $error, 
		hash => "${log}_$srpm", 
		srpm => $srpm,
		timeout => 600, 
		retry => 2,
		debug_mail => $run->{debug},
		freq => 1, 
		wait_regexp => { 'database locked' => \&wait_urpmi },
		error_regexp => 'unable to access',
		log => $log_spool)) {
	    $cache->{failure}{$srpm} = 1;
	    $run->{status}{$srpm} = 'binary_test_failure';
	    return 0;
	}
	1;
}

sub are_installed {
    my ($chroot, @pkgs) = @_;
    @pkgs = map { -f "$chroot$_" && `rpm -qp --qf %{name} $chroot$_` || $_ } @pkgs;
    system("rpm -q --root $chroot @pkgs") == 0;
}

sub install_packages {
    my ($self, $title, $chroot_tmp, $local_spool, $pack_provide, $log, $error, $opt, @packages) = @_;

    my $maintainer = $opt->{maintainer};
    my $run = $self->{run};
    my $config = $self->{config};
    my $cache = $run->{cache};
    my $program_name = $run->{program_name};
    my $ok = 1;
    my @to_install;

    plog('DEBUG', "installing @packages");

    if ($run->{chrooted_urpmi}) {
       	@to_install = map { s/$chroot_tmp//; $_ } @packages;
    } else {
	push @to_install, @packages;
    }

    @to_install or return 1;

    (my $log_dirname = $title) =~ s/.*:(.*)\.src.rpm/$1/;

    my $log_spool = "$local_spool/log/$log_dirname/";

    mkdir $log_spool;

    my @rpm = grep { !/\.src\.rpm$/ } @to_install;

    if ($opt->{check}
		&& -f "$chroot_tmp/bin/rpm"
		&& @rpm
		&& are_installed($chroot_tmp, @to_install)) {
	return 1;
    }

    plog('INFO', "install dependencies using urpmi");

    if (!perform_command(
	    "$self->{urpmi_command} @to_install", 
	    $run, $config, $cache,
	    use_iurt_root_command => $self->{use_iurt_root_command},
	    error => $error,
	    logname => $log,
	    hash => "${log}_$title", 
	    timeout => 3600, # [pixel] 10 minutes was not enough, 1 hour should be better
	    srpm => $title,
	    freq => 1,
	    #cc => $cc, 
	    retry => 3,
	    debug_mail => $run->{debug},
	    error_regexp => 'cannot be installed',
	    wait_regexp => { 
		'database locked' => \&wait_urpmi, 
	    }, 
	    log => $log_spool,
	    callback => sub { 
		my ($opt, $output) = @_;
		plog('DEBUG', "calling callback for $opt->{hash}");

# 20060614
# it seems the is needed urpmi error is due to something else (likely a
# database corruption error).	    
# my @missing_deps = $output =~ /(?:(\S+) is needed by )|(?:\(due to unsatisfied ([^[ ]*)(?: (.*)|\[(.*)\])?\))/g;
#

		my @missing_deps = $output =~ /([^ \n]+) \(due to unsatisfied ([^[ \n]*)(?: ([^\n]*)|\[([^\n]*)\])?\)/g;

		# <mrl> 20071106 FIXME: This should not be needed anymore
		# as it seems that rpm db corruption is making urpmi
		# returning false problem on deps installation, try
		# to compile anyway

		if (!@missing_deps) {
		    plog('DEBUG', 'missing_deps is empty, aborting.');
		    plog('DEBUG', "output had: __ $output __");
		    return 1;
		}

		while (my $missing_package = shift @missing_deps) {
		    my $missing_deps = shift @missing_deps;
		    my $version = shift @missing_deps;
		    my $version2 = shift @missing_deps;
		    $version ||= $version2 || 0;
		    my $p = $pack_provide->{$missing_deps} || $missing_deps;
		    my ($missing_package_name, $first_maint);
		    if ($missing_package !~ /\.src$/) {
			($first_maint, $missing_package_name) = get_maint($run, $missing_package);
			plog(5, "likely $missing_package_name need to be rebuilt ($first_maint)");
		    } else {
			$missing_package = '';
		    }

		    my ($other_maint) = get_maint($run, $p);
		    plog('FAIL', "missing dep: $missing_deps ($other_maint) missing_package $missing_package ($first_maint)");
		    $run->{status}{$title} = 'missing_dep';

		    $opt->{mail} = $maintainer || $config->{admin};

		    # remember what is needed, and do not try to
		    # recompile until it is available

		    if ($missing_package) {
			$opt->{error} = "[MISSING] $missing_deps, needed by $missing_package to build $title, is not available on $run->{my_arch} (rebuild $missing_package?)";
			$cache->{needed}{$title}{$missing_deps} = { package => $missing_package , version => $version, maint => $first_maint || $other_maint || $maintainer };
		    } else {
			$opt->{error} = "[MISSING] $missing_deps, needed to build $title, is not available on $run->{my_arch}";
			$cache->{needed}{$title}{$missing_deps} = { package => $missing_package , version => $version, maint => $maintainer || $other_maint };
		    }
		} 
		0;
	    },
	)) {
	plog('DEBUG', "urpmi command failed.");
	if (!clean_process($run, "$self->{urpmi_command} @to_install", $run->{verbose})) {
	    dump_cache_par($run);
	    die "FATAL $program_name: Could not have urpmi working !";
	}
	$ok = 0;
    }

    if ($ok && (!@rpm || are_installed($chroot_tmp, @rpm))) {
	plog("installation successful");
	$ok = 1;
    }
    else {
	plog(1, "ERROR: Failed to install initial packages");
	$ok = 0;
    }

    $ok;
}

sub clean_urpmi_process {
    my ($self) = @_;
    my $run = $self->{run};
    my $program_name = $run->{program_name};
    if (!$run->{chrooted_urpmi}) {
	my $match = $self->{urpmi_command} or return;
	if (!clean_process($run, $match, $run->{verbose})) {
	    dump_cache_par($run);
	    die "FATAL $program_name: Could not have urpmi working !";
	}
    }
}

sub update_srpm {
	my ($self, $dir, $rpm, $wrong_rpm) = @_;
	my $run = $self->{run};
	my $cache = $run->{cache};
	my ($arch) = $rpm =~ /([^\.]+)\.rpm$/ or return 0;
	my $srpm = $cache->{rpm_srpm}{$rpm};
	if (!$srpm) {
		my $hdr = RPM4::Header->new("$dir/$rpm");
		$hdr or return 0;
		$srpm = $hdr->queryformat('%{SOURCERPM}');
		$cache->{rpm_srpm}{$rpm} = $srpm;
	}
	$srpm = fix_srpm_name($cache, $srpm, $rpm, $wrong_rpm);
	$arch, $srpm;
}

sub fix_srpm_name {
	my ($cache, $srpm, $rpm, $wrong_rpm) = @_;
	my $old_srpm = $srpm;
	if ($srpm =~ s/^lib64/lib/) {
		push @$wrong_rpm, [ $old_srpm, $rpm ] if ref $wrong_rpm;
		$cache->{rpm_srpm}{$rpm} = $srpm;
	}
	$srpm;
}

sub recreate_srpm {
    my ($_self, $run, $config, $chroot_tmp, $dir, $srpm, $luser, $b_retry) = @_;
# recreate a new srpm for buildarch condition in the spec file
    my $program_name = $run->{program_name};
    my $cache = $run->{cache};
    my $with_flags = $run->{with_flags};

    plog('NOTIFY', "recreate srpm: $srpm");

    perform_command([ 
	sub { 
	    my ($s, $d) = @_; 
	    sudo($run, $config, '--cp', $s, $d) } , [ "$dir/$srpm", "$chroot_tmp/home/$luser/rpm/SRPMS/" ] ], 
	$run, $config, $cache, 
	type => 'perl',
	mail => $config->{admin}, 
	error => "[REBUILD] cannot copy $srpm to $chroot_tmp", 
	debug_mail => $run->{debug},
	hash => "copy_$srpm") or return;

    my %opt = (mail => $config->{admin}, 
	error => "[REBUILD] cannot install $srpm in $chroot_tmp", 
 	use_iurt_root_command => 1,
	debug_mail => $run->{debug},
	hash => "install_$srpm",
	retry => $b_retry,
	callback => sub { 
	    my ($opt, $output) = @_;
	    plog('DEBUG', "calling callback for $opt->{hash}");
	    if ($output =~ /warning: (group|user) .* does not exist - using root|Header V3 DSA signature/i) {
		return 1;
	    } elsif ($output =~ /user $luser does not exist|cannot write to \%sourcedir/) {
		plog('WARN', "WARNING: chroot seems corrupted!");
		$opt->{error} = "[CHROOT] chroot is corrupted";
		$opt->{retry} ||= 1;
		return;
	    }
	    1;
	});
    plog('DEBUG', "recreating src.rpm...");
    if (!perform_command(qq(chroot $chroot_tmp su $luser -c "rpm -i /home/$luser/rpm/SRPMS/$srpm"), 
	    $run, $config, $cache, %opt)) {
	plog("ERROR: chrooting failed (retry $opt{retry}") if $run->{debug};
	if ($opt{retry}) {
	    check_build_chroot($run->{chroot_path}, $run->{chroot_tar}, $run,  $config) or return;
	    return -1;
	}
	return;
    }
    
    my $spec;
    my $oldsrpm = "$chroot_tmp/home/$luser/rpm/SRPMS/$srpm";
    my $filelist = `rpm -qlp $oldsrpm`;
    my ($name) = $srpm =~ /(?:.*:)?(.*)-[^-]+-[^-]+\.src\.rpm$/;
    foreach my $file (split "\n", $filelist) {
	if ($file =~ /(.*)\.spec/) {
	    if (!$spec) {
		$spec = $file;
	    } elsif ($1 eq $name) {
		$spec = $file;
	    }
	}
    } 
    # 20060515 This should not be necessairy any more if urpmi *.spec works, but it doesn't
    #
    my $ret = perform_command(qq(chroot $chroot_tmp su $luser -c "rpmbuild --nodeps -bs $with_flags /home/$luser/rpm/SPECS/$spec"), 
	$run, $config, $cache, 
	use_iurt_root_command => 1,
	mail => $config->{admin}, 
	error => "[REBUILD] cannot create $srpm in $chroot_tmp", 
	debug_mail => $run->{debug},
	hash => "create_$srpm"
    );

    # Return if we can't regenerate srpm
    #
    return (0, ,) unless $ret;

    # CM: was: foreach my $file (readdir $dir)
    #     The above line returned entries in a strange order in my test
    #     system, such as
    #      .. 
    #      cowsay-3.03-11mdv2007.1.src.rpm
    #      cowsay-3.03-11mdv2007.0.src.rpm
    #      .
    #     assigning '.' to $new_rpm. Now sorting the output.

    # we can not ask rpm the generated srpm name 
    # we can not rely on build time (one of the src.rpm may have been built on a machine with wrong time)
    # let's say that if we have several one, we want the non original one
    my $file = $oldsrpm;
    foreach my $f (glob "$chroot_tmp/home/$luser/rpm/SRPMS/$name-*.src.rpm") {
	$file = $f if $f ne $oldsrpm;
    }
    my ($new_srpm) = basename($file);
    my $prefix = get_package_prefix($srpm);
    my $newfile = "$chroot_tmp/home/$luser/rpm/SRPMS/$prefix$new_srpm";
    if (-f $file && $newfile ne $file) {
	if (-f $newfile) {
	    sudo($run, $config, '--rm', $newfile) or die "$program_name: could not delete $newfile ($!)";
	}
	sudo($run, $config, '--ln', $file, $newfile) or die "$program_name: linking $file to $newfile failed ($!)";
	unlink $file;
	unlink $oldsrpm if $oldsrpm ne $newfile;
    }
    plog('NOTIFY', "new srpm: $prefix$new_srpm");
    ($ret, "$prefix$new_srpm", $spec);
}

1;
