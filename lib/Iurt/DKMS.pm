package Iurt::DKMS;

use strict;
use base qw(Exporter);
use MDV::Distribconf::Build;
use Iurt::Chroot qw(clean_chroot add_local_user dump_rpmmacros);
use Iurt::Config qw(get_maint get_prefix dump_cache);
use Iurt::Mail qw(sendmail);
use File::NCopy qw(copy);
use Iurt::Process qw(sudo);
use Iurt::Util qw(plog);
use RPM4::Header;
use MDK::Common;

our @EXPORT = qw(
	search_dkms
	dkms_compile
);

sub new {
    my ($class, %opt) = @_;
    my $self = bless {
        config  => $opt{config},
        run => $opt{run},
    }, $class;

    $self;
}

=head2 search_dkms($run, $config)

Search for dkms packages which needs to be recompiled for new kernel
I<$run> is the running environment
I<%config> is the current configuration values
Return true.

=cut

sub search_dkms {
    my ($self) = @_;
    my $config = $self->{config};
    my $run = $self->{run};
    my $arch = $run->{my_arch};
    my $root = $config->{repository};
    my $distro = $run->{distro};
    my $cache = $run->{cache};
    my $path = "$root/$distro/$arch";
    if (!-d $path) {
	plog('ERROR', "ERROR: $path is not a directory");
	return;
    }
    my $distrib = MDV::Distribconf::Build->new($path);
    plog("getting media config from $path");
    if (!$distrib->loadtree) {
	plog('ERROR', "ERROR: $path does not seem to be a distribution tree");
	return;
    }
    $distrib->parse_mediacfg;
    my %dkms;
    my @kernel;
    my %modules;
    my %kernel_source;
    foreach my $media ($distrib->listmedia) {
	$distrib->getvalue($media, "arch") ne $arch and next;
	$media =~ /(SRPMS|debug_)/ and next;
	my $path = $distrib->getfullpath($media, 'path');
	my $media_ok = $run->{dkms}{media} ? $media =~ /$run->{dkms}{media}/ : 1;
	my $kmedia_ok = $run->{dkms}{kmedia} ? $media =~ /$run->{dkms}{kmedia}/ : 1;
	plog("searching in $path");
	opendir(my $rpmdh, $path);
	foreach my $rpm (readdir $rpmdh) {
	    if ($rpm =~ /^dkms-(.*)-([^-]+-[^-]+)\.[^.]+\.rpm/) {
		# we only check for kernel or modules in this media
		$media_ok or next;
		my ($name, $version) = ($1, $2);
		my $package_ok = $run->{dkms}{package} ? $name =~ /$run->{dkms}{package}/ : 1;
		$package_ok or next;
		my $hdr = RPM4::Header->new("$path/$rpm");
		my $files = $hdr->queryformat('[%{FILENAMES} ])');
		my ($modulesourcedir) = $files =~ m, /usr/src/([^/ ]+),;
		my $script = $hdr->queryformat('%{POSTIN})');
		my ($realname) = $script =~ /\s+-m\s+(\S+)/;
		$realname ||= $name;
		my ($realversion) = $script =~ /\s+-v\s+(\S+)/;
		$realversion ||= $version;
		plog('NOTIFY', "dkms $name version $version source $modulesourcedir realname $realname realversion $realversion");
		push @{$dkms{$media}}, [ $name, $version, $modulesourcedir, $realname, $realversion, "$path/$rpm" ];
	    } elsif ($rpm =~ /^kernel-((?:[^-]+-)?[^-]+.*)-[^-]+-[^-]+\.[^.]+\.rpm/ && $rpm !~ /win4lin|latest|debug|stripped|BOOT|xen|doc/) {
		# we do not check for kernel in this media
		$kmedia_ok or next;
		my $version = $1;
		my $package_ok = $run->{dkms}{kversion} ? $version =~ /$run->{dkms}{kversion}/ : 1;
		$package_ok or next;
		my $hdr = RPM4::Header->new("$path/$rpm");
		my $files = $hdr->queryformat('[%{FILENAMES}\n]');
		if ($version =~ /(.*)source-(.*)/ || $version =~ /(.*)devel-(.*)/) {
		    my ($sourcedir) = $files =~ m,^/usr/src/([^/ ]+)$,m;
		    plog('NOTIFY', "kernel source $version (sourcedir $sourcedir)");
		    $kernel_source{$version} = $sourcedir;
		} else {
		    my ($modulesdir) = $files =~ m,^/lib/modules/([^/ ]+)$,m;
		    if ($modulesdir) {
                        plog('NOTIFY', "kernel $version (modules dir $modulesdir)");
                        push @kernel, [ $version, $modulesdir ];
		    } else {
                        plog('NOTIFY', "skipping kernel $version (no modules dir)");
		    }
		}
	    } elsif ($rpm =~ /^(.*)-kernel-([^-]+-[^-]+.*)-([^-]+-[^-]+)\.[^.]+\.rpm$/ && $rpm !~ /-latest-/) {
		plog('NOTIFY', "modules $1 version $3 for kernel $2");
		# module version kernel
		$modules{$1}{$3}{$2} = 1;
	    }
	}
    }
    my $nb;
    foreach my $media (keys %dkms) {
	foreach my $dkms (@{$dkms{$media}}) {
	    my ($module, $version, $modulesourcedir, $realmodule, $realversion, $file) = @$dkms;
	    foreach my $k (@kernel) {
		my ($kernel, $modulesdir) = @$k;
		plog("checking $realmodule-kernel-$modulesdir-$realversion");
		next if $cache->{dkms}{"$realmodule-kernel-$modulesdir-$realversion"} && !$run->{ignore_failure};
		if (!$modules{$realmodule}{$realversion}{$modulesdir}) {
		    my (@choices);
		    if (my ($prefix, $v) = $kernel =~ /^(.*?-?)(2\..*)/) {
			if (exists $kernel_source{"${prefix}source-$v"}) {
			    # main flavour
			    push @choices, "${prefix}devel-$v", "${prefix}source-$v";
			} elsif ($prefix) {
			    # other flavour
			    push @choices, "${prefix}devel-$v";
			    if (my ($main_prefix) = $prefix =~ /^([^-]+-)?[^-]+-$/) {
				push @choices, "${main_prefix}source-$v";
			    }
			}
		    }
		    my $source = find { $kernel_source{$_} } @choices;
		    if (!$source) {
			plog('ERROR', "ERROR: no source for kernel $kernel (tried " . join(", ", @choices) . ")");
			next;
		    }
		    plog("dkms module $module version $version should be compiled for kernel $kernel ($source)");
		    $nb++;
		    push @{$run->{dkms_todo}}, [ $module, $version, $modulesourcedir, $realmodule, $realversion, $file, $kernel, $modulesdir, $source, $kernel_source{$source}, $media ];
		}
		$modules{$realmodule}{$realversion}{$modulesdir}++;
	    }
	}
    }
    foreach my $module (keys %modules) {
	foreach my $version (keys %{$modules{$module}}) {
	    foreach my $modulesdir (keys %{$modules{$module}{$version}}) {
		next if $modules{$module}{$version}{$modulesdir} < 2;
		plog('WARN', "dkms module $module version $version for kernel $modulesdir is obsolete");
		push @{$run->{dkms_obsolete}}, "$module-kernel-$modulesdir-$version";
	    }
	}
    }
    $nb;
}

=head2 dkms_compile($class, $local_spool, $done)

Compile the dkms against the various provided kernel
Return true.

=cut

sub dkms_compile {
    my ($self, $local_spool, $done) = @_;
    my $config = $self->{config};
    my $run = $self->{run};
    my $urpmi = $run->{urpmi};
    # For dkms build, the chroot is only installed once and the all the modules are recompiled 
    my $chroot_tmp = $run->{chroot_tmp};
    my $chroot_tar = $run->{chroot_tar};
    my $cache = $run->{cache};
    my $luser = $run->{user};
    my $to_compile = $run->{to_compile};

    plog("building chroot: $chroot_tmp");
    clean_chroot($chroot_tmp, $chroot_tar, $run, $config);
    my %installed;
    # initialize urpmi command
    $urpmi->urpmi_command($chroot_tmp);
    # also add macros for root
    add_local_user($chroot_tmp, $run, $config, $luser, $run->{uid});

    if (!dump_rpmmacros($run, $config, "$chroot_tmp/home/$luser/.rpmmacros") || !dump_rpmmacros($run, $config, "$chroot_tmp/root/.rpmmacros")) {
	plog('ERROR', "ERROR: adding rpmmacros failed");
	return;
    }

    my $kerver = `uname -r`;
    chomp $kerver;

    my $dkms_spool = "$local_spool/dkms/";
    -d $dkms_spool or mkdir $dkms_spool;

    foreach my $dkms_todo (@{$run->{dkms_todo}}) {
	my ($name, $version, $_modulesourcedir, $realname, $realversion, $file, $kernel, $modulesdir, $source, $sourcedir, $media) = @$dkms_todo;
	$done++;

	$media = $run->{dkms}{umedia} if $run->{dkms}{umedia};

	plog("dkms modules $name version $version for kernel $kernel [$done/$to_compile]");

	# install kernel and dkms if not already installed
	my $ok = 1;
	# make sure dkms commands are not run in rpm post scripts
	my $dkms_conf = $chroot_tmp . "/etc/dkms/framework.conf";
	system("sudo sh -c 'mkdir -p `dirname $dkms_conf`; echo exit 0 > $dkms_conf'");

	foreach my $pkg ("kernel-$source", "dkms", "kernel-$kernel", $file) {
	    my $pkgname = basename($pkg);
	    if ($run->{chrooted_urpmi} && -f $pkg) {
		copy($pkg, "$chroot_tmp/tmp/");
		$pkg = "/tmp/$pkgname";
	    }
	    if (!$installed{$pkg}) {
		plog('DEBUG', "install package: $pkg");
		if (!$urpmi->install_packages("dkms-$name-$version", $chroot_tmp, $local_spool, {}, "dkms_$pkgname", "[DKMS] package $pkg installation error", { maintainer => $config->{admin} }, $pkg)) {
		    plog('ERROR', "ERROR: error installing package $pkg");
		    $ok = 0;
		    last;
		}
		$installed{$pkg} = 1;
	    }
	    # recreate the appropriate kernel source link
	}
	system("sudo rm -f $dkms_conf");
	$ok or next;

	# symlink modules build dir if not using devel package
	my $modules_build_dir = "$chroot_tmp/lib/modules/$modulesdir/build";
	if (! -e $modules_build_dir) {
	    plog('DEBUG', "symlink from $modules_build_dir to /usr/src/$sourcedir");

	    if (system("sudo ln -sf /usr/src/$sourcedir $modules_build_dir")) {
		plog('ERROR', "ERROR: linking failed ($!)");
		next;
	    }
	}

	foreach my $cmd ('add', 'build') {
	    my $command = "TMP=/home/$luser/tmp/ sudo chroot $chroot_tmp /usr/sbin/dkms $cmd -m $realname -v $realversion --rpm_safe_upgrade -k $modulesdir";
	    plog('DEBUG', "execute: $command");
	    system($command);
	}

	$cache->{dkms}{"$realname-kernel-$modulesdir-$realversion"} = 1;

	if ($kerver ne $modulesdir && -d "$chroot_tmp/var/lib/dkms/$realname/$realversion/$kerver/") {
	    # some of the dkms modules do not handle correclty the -k option
	    # and use uname -r to find kernel modules dir
	    plog('ERROR', "ERROR: modules have been built for current kernel ($kerver) instead of $modulesdir");
	    system("sudo rm -rf $chroot_tmp/var/lib/dkms/$realname/$realversion/$kerver");
	    require Text::Wrap;
	    sendmail("Iurt admins <$config->{admin}>", '' , "Iurt failure for $name",
		     Text::Wrap::wrap("", "", join('', map { "$_\n" }
		      "Modules for $name have been built for the current kernel ($kerver) while they should have been build for $modulesdir.",
		      "Please report to the maintainer of $name",
		     )),
		     "Iurt the rebuild bot <$config->{admin}>", 0, $config);
	    next;
	}

	if (system("sudo chroot $chroot_tmp /usr/sbin/dkms mkrpm -m $realname -v $realversion --rpm_safe_upgrade -k $modulesdir")) {
	    plog('FAIL', "build failed ($!)");
	    next;
	}

	plog('OK', "build succesful, copy packages to $dkms_spool/$media");

	-d "$dkms_spool/$media" or mkdir_p "$dkms_spool/$media";

	my @dkms_rpm_dirs = ("/home/$luser/rpm/RPMS/*", "/usr/src/rpm/RPMS/*", "/var/lib/dkms/$realname/$realversion/rpm");
	my $copied;
	foreach (@dkms_rpm_dirs) {
	    my $rpms = "$chroot_tmp$_/*.rpm";
	    if (system("cp $rpms $dkms_spool/$media/ &>/dev/null") == 0) {
		$copied = 1;
		sudo($config, '--rm', $rpms)
		    or plog('ERROR', "ERROR: could not delete dkms packages from $rpms ($!)");
		last;
	    }
	}
	plog('ERROR', "ERROR: could not copy dkms packages from " .
		      join(" or ", map { "$chroot_tmp$_/*.rpm" } @dkms_rpm_dirs) .
		      " to $dkms_spool/$media ($!)") if !$copied;

	process_dkms_queue($self, 0, 0, $media, "$dkms_spool/$media");
	# compile dkms modules
    }
    dump_cache($run);
    $done;
}  
# FIXME will replace the iurt2 process_qeue when youri-queue is active
sub process_dkms_queue {
    my ($self, $wrong_rpm, $quiet, $media, $dir) = @_;
    my $run = $self->{run};
    return if !$run->{upload} && $quiet;
    my $config = $self->{config};
    my $cache = $run->{cache};
    $media ||= $run->{media};
    my $urpmi = $run->{urpmi};

    $dir ||= "$config->{local_upload}/iurt/$run->{distro_tag}/$run->{my_arch}/$media}/";

    plog("processing $dir");
    opendir my $rpmdir, $dir or return;
    # get a new prefix for each package so that they will not be all rejected if only one is wrong
    my $prefix = get_prefix('iurt');
    foreach my $rpm (readdir $rpmdir) {
	my ($rarch, $srpm) = $urpmi->update_srpm($dir, $rpm, $wrong_rpm);
	$rarch or next;
	plog('DEBUG', $rpm);
	next if !$run->{upload};

	plog("copy $rpm to $config->{upload_queue}/$run->{distro}/$media/");

	# recheck if the package has not been uploaded in the meantime
	my $rpms_dir = "$config->{repository}/$run->{distro}/$run->{my_arch}/media/$media/";
	if (! -f "$rpms_dir/$rpm") {
	    my $err = system("/usr/bin/scp", "$dir/$rpm", $config->{upload_queue} . "/$run->{distro}/$media/$prefix$rpm");
	    # try to keep the opportunity to prevent disk full "
	    if ($err) {
		#$run->{LOG}->("ERROR process_queue: cannot copy $dir/$rpm to ", $config->{upload_queue}, "/$run->{distro}/$media/$prefix$rpm ($!)\n");
		next;
	    }
	}
	if ($run->{upload_source}) {
	    #should not be necessary
	}
	# should not be necessary to use sudo
	sudo($config, '--rm', "$dir/$rpm");
	$cache->{queue}{$srpm} = 1;
    }
    closedir $rpmdir;
}

1;
