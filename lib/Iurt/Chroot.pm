package Iurt::Chroot;

use strict;
use base qw(Exporter);
use MDV::Distribconf::Build;
use MDK::Common;
use Iurt::Process qw(clean sudo);
use Iurt::Config qw(dump_cache_par);
use Iurt::Util qw(plog);
use File::Temp 'mktemp';
use File::Path 'mkpath';

our @EXPORT = qw(
    clean_chroot_tmp
    clean_all_chroot_tmp
    clean_chroot
    update_chroot
    dump_rpmmacros
    add_local_user
    create_temp_chroot
    remove_chroot
    create_chroot
    create_build_chroot
    check_chroot
    check_build_chroot
);
    
my $sudo = '/usr/bin/sudo';

=head2 clean_chroot($chroot, $run, $only_clean)

Create or clean a chroot
I<$chroot> chroot path
I<$run> is the running environment
I<%only_clean> only clean the chroot, do not create a new one
Return true.

=cut

sub clean_chroot {
    my ($chroot, $chroot_tar, $run, $config, $o_only_clean, $o_only_tar) = @_;

    plog('DEBUG', "clean chroot");
    if (-d $chroot && !$o_only_tar) {
        sudo($run, $config, "--umount", "$chroot/proc");
        sudo($run, $config, "--umount", "$chroot/dev/pts");
	if ($run->{icecream}) {
            sudo($run, $config, "--umount", "$chroot/var/cache/icecream");
	}
	if (-d "$chroot/urpmi_medias/") {
            sudo($run, $config, "--umount", "$chroot/urpmi_medias");
	}

	# Do not run rm if there is something still mounted there
	open(my $FP, "/proc/mounts") or die $!;
	my @list = grep { /$chroot/ } <$FP>;
	close($FP);
	if (@list >= 0) {
	    # Still referenced
	    return 1;
	}

	sudo($run, $config, '--rm', '-r', $chroot);
    }

    return 1 if $o_only_clean;

    mkdir $chroot;

    # various integrity checking
    if ($o_only_tar
	&& -f "$chroot/home/builder/.rpmmacros"
	&& -d "$chroot/home/builder"
	&& -d "$chroot/proc") {
	return 1;
    }
 
    sudo($run, $config, '--untar', $chroot_tar, $chroot);
    if (!create_build_chroot($chroot, $chroot_tar, $run, $config)) {
	plog('ERROR', "Failed to create chroot");
        return;
    }

    if (!dump_rpmmacros($run, $config, "$chroot/home/builder/.rpmmacros")) {
	plog('ERROR', "Failed to dump macros");
	return;
    }
    if (!sudo($run, $config, '--bindmount', "/proc", "$chroot/proc")) {
	plog('ERROR', "Failed to mount proc");
	return;
    }
    if (!sudo($run, $config, '--bindmount', "/dev/pts", "$chroot/dev/pts")) {
	plog('ERROR', "Failed to mount dev/pts");
	sudo($run, $config, "--umount", "$chroot/proc");
	return;
    }
    if ($run->{icecream}) {
	system("$sudo mkdir -p $chroot/var/cache/icecream");
	if (!sudo($run, $config, '--bindmount', "/var/cache/icecream", "$chroot/var/cache/icecream")) {
	    plog('ERROR', "Failed to mount var/cache/icecream");
	    sudo($run, $config, "--umount", "$chroot/proc");
	    sudo($run, $config, "--umount", "$chroot/dev/pts");
	    return;
	}
    }

    if ($run->{additional_media} && $run->{additional_media}{repository}) {
	my $rep = $run->{additional_media}{repository};
	if ($rep !~ m/^(http:|ftp:)/) {
	    my $mount_point = "$chroot/urpmi_medias";
	    my $url = $rep;
	    $url =~ s!^file://!!;
	    sudo($run, $config, '--mkdir', '-p', $mount_point);
	    if (!sudo($run, $config, '--bindmount', $url, $mount_point)) {
		plog('ERROR', "Failed to mount $url on $mount_point");
		sudo($run, $config, "--umount", "$chroot/proc");
		sudo($run, $config, "--umount", "$chroot/dev/pts");
		if ($run->{icecream}) {
		    sudo($run, $config, "--umount", "$chroot/var/cache/icecream");
		}
		return;
	    }
	}
    }
    1;
}  

=head2 update_chroot($chroot, $run, $only_clean)

Updates chroot
I<$chroot> chroot path
I<$run> is the running environment
I<%only_clean> only clean the chroot, do not create a new one
Return true.

=cut

sub update_chroot {
    my ($_chroot, $_chroot_tar, $_run, $_config, $_only_clean, $_only_tar) = @_;

    plog('DEBUG', "update chroot");

#    my $urpmi = $run->{urpmi};
#    $urpmi->auto_select($chroot);

}

sub dump_rpmmacros {
    my ($run, $config, $file) = @_;
    my $f;

    #plog("adding rpmmacros to $file");

    my $tmpfile = "/tmp/rpmmacros";
    if (!open $f, ">$tmpfile") {
	plog("ERROR: could not open $tmpfile ($!)");
	return 0;
    }
    my $packager = $run->{packager} || $config->{packager};

    print $f qq(\%_topdir                \%(echo \$HOME)/rpm
\%_tmppath               \%(echo \$HOME)/rpm/tmp/
\%distribution           $config->{distribution}
\%vendor                 $config->{vendor}
\%packager               $packager
);
    print $f join "\n", @{$run->{rpmmacros}} if defined $run->{rpmmacros};
    close $f;

    my $ret = sudo($run, $config, '--cp', $tmpfile, $file);
    unlink $tmpfile;

    if (!$ret) {
	plog("ERROR: could not write $file ($!)");
	return 0;
    }

    1;
}

sub add_local_user {
    my ($chroot_tmp, $run, $config, $luser, $uid) = @_;

    # change the builder user to the local user id
    # FIXME it seems that unionfs does not handle well the change of the
    #       uid of files
    # if (system(qq|sudo chroot $chroot_tmp usermod -u $run->{uid} builder|)) {
    
    if ($uid) {
	if (!sudo($run, $config, "--useradd", $chroot_tmp, $luser, $uid)) {
	    plog('ERROR', "ERROR: setting userid $uid to $luser in " .
		"$chroot_tmp failed, checking the chroot");
	    check_build_chroot($run->{chroot_path}, $run->{chroot_tar}, $run,
		$config) or return;
	}
    } else {
	# the program has been launch as root, setting the home to /home/root for compatibility
	system($sudo, 'chroot', $chroot_tmp, 'usermod', '-d', "/home/$luser", '-u', $uid, '-o', '-l', $luser, 'root');
    }

    dump_rpmmacros($run, $config, "$chroot_tmp/home/$luser/.rpmmacros") or return;

    1;
}

sub create_temp_chroot {
    my ($run, $config, $_cache, $chroot_tmp, $chroot_tar, $o_srpm) = @_;

    plog("Install new chroot");
    plog('DEBUG', "... in $chroot_tmp");
    clean_chroot($chroot_tmp, $chroot_tar, $run, $config) or return;
    update_chroot($chroot_tmp, $run, $config);

    $chroot_tmp;
}

sub remove_chroot {
    my ($run, $dir, $func, $prefix) = @_;

    plog("Remove existing chroot");
    plog('DEBUG', "... dir $dir all $run->{clean_all} prefix $prefix");

    if ($run->{clean_all}) {
	opendir(my $chroot_dir, $dir);
	foreach (readdir $chroot_dir) {
	    next if !-d "$dir/$_" || /\.{1,2}/;
	    plog("cleaning old chroot for $_ in $dir");
	    $func->($run, "$dir/$_", $prefix);
	}
    } else {
	foreach my $user (@{$run->{clean}}) {
	    plog("cleaning old chroot for $user in $dir");
	    $func->($run, "$dir/$user", $prefix);
	}
    }
} 

sub clean_mnt {
    my ($run, $mount_point, $verbose) = @_;
    return clean($run, $mount_point, "/sbin/fuser", "$sudo /sbin/fuser -k", $verbose);
}

sub clean_all_chroot_tmp {
    my ($run, $chroot_dir, $prefix) = @_;

    plog(1, "cleaning all old chroot remaining dir in $chroot_dir");

    my $dir;
    if (!opendir $dir, $chroot_dir) { 
	plog("ERROR: can't open $chroot_dir ($!)");
	return;
    }
    foreach (readdir($dir)) {
	/$prefix/ or next;
	clean_chroot_tmp($run, $chroot_dir, $_);
    }
    closedir $dir;
}

sub clean_chroot_tmp {
    my ($run, $chroot_dir, $dir) = @_;
    my $d = "$chroot_dir/$dir";

    foreach my $m ('proc', 'dev/pts', 'urpmi_medias', 'var/cache/icecream') {
	if (system("$sudo umount $d/$m &>/dev/null") && $run->{verbose} > 1) { 
	    plog("ERROR: could not umount /$m in $d/");
	    # FIXME: <mrl> We can't go on, otherelse we will remove something
	    # that we shouldn't. But for that, we should:
	    #  a) Check for all mount-points inside the chroot
	    #  b) Try to unmount only the needed ones, otherelse the errors
	    # can be misleading.
	}
    }

    plog(1, "cleaning $d");
    system("$sudo /sbin/fuser -k $d &> /dev/null");
    plog(1, "removing $d");
    system($sudo, 'rm', '-rf', $d);
}

sub check_mounted {
    my ($mount_point, $type) = @_;

    my $mount;
    if (!open $mount, '/proc/mounts') {
	plog("ERROR: could not open /proc/mounts");
	return;
    }
    $mount_point =~ s,//+,/,g;
    local $_;
    while (<$mount>) {
	return 1 if /^\w+ $mount_point $type /;
    }
    0;
}

sub create_build_chroot {
    my ($chroot, $chroot_tar, $run, $config) = @_;
    create_chroot($chroot, $chroot_tar, $run, $config,
			{ packages => $config->{basesystem_packages} });
}

sub create_chroot {
    my ($chroot, $chroot_tar, $run, $config, $opt) = @_;
    my $tmp_tar = mktemp("$chroot_tar.tmp.XXXXXX");
    my $tmp_chroot = mktemp("$chroot.tmp.XXXXXX");
    my $rebuild;
    my $clean = sub {
	plog("Remove temporary chroot tarball");
	sudo($run, $config, '--rm', '-r', $tmp_chroot, $tmp_tar);
    };

    plog('NOTIFY', "creating chroot");
    plog('DEBUG', "... with packages " . join(', ', @{$opt->{packages}}));

    mkdir_p($tmp_chroot);
    if (!-f $chroot_tar) {
        plog("rebuild chroot tarball");
        $rebuild = 1;
    } else {
        link $chroot_tar, $tmp_tar or die "FATAL: could not initialize chroot ($!)\n";

        plog('DEBUG', "decompressing /var/log/qa from $chroot_tar in $tmp_chroot");
        sudo($run, $config, '--untar', $chroot_tar, $tmp_chroot, "./var/log/qa");

        my $tmp_urpmi = mktemp("$chroot.tmp.XXXXXX");
        my @installed_pkgs = grep { !/^gpg-pubkey/ } chomp_(cat_("$tmp_chroot/var/log/qa"));
        my @available_pkgs = chomp_(`urpmq --urpmi-root $tmp_urpmi --use-distrib $run->{urpmi}{distrib_url} --list -f 2>/dev/null`);
        my @removed_pkgs = difference2(\@installed_pkgs, \@available_pkgs);
        rm_rf($tmp_urpmi);

        if (@installed_pkgs) {
            if (@removed_pkgs) {
                plog('DEBUG', "changed packages: @removed_pkgs");
                plog('NOTIFY', "Rebuilding chroot tarball");
                $rebuild = 1;
            } else {
                plog('NOTIFY', "chroot tarball is already up-to-date");
                link $tmp_tar, $chroot_tar;
            }
        } else {
            plog('DEBUG', "can't open $tmp_chroot/var/log/qa");
            plog('ERROR', "can't check chroot, recreating");
            $rebuild = 1;
        }
    }

    if ($rebuild) {
	    if (!build_chroot($run, $config, $tmp_chroot, $chroot_tar, $opt)) {
		plog('NOTIFY', "creating chroot failed.");
		$clean->();
		sudo($run, $config, '--rm', '-r', $chroot, $chroot_tar);
		return;
	    }
    }

    if (!-d $chroot || $rebuild) {
	plog('DEBUG', "recreate chroot $chroot");
	plog('NOTIFY', "recreate chroot");
	my $urpmi = $run->{urpmi};
	$urpmi->clean_urpmi_process($chroot);
	sudo($run, $config, '--rm', '-r', $chroot, $tmp_tar);
	mkdir_p $chroot;
	sudo($run, $config, '--untar', $chroot_tar, $chroot);
	plog('NOTIFY', "chroot recreated in $chroot_tar (live in $chroot)");
    }
    
    $clean->();

    1;
}

sub build_chroot {
    my ($run, $config, $tmp_chroot, $chroot_tar, $opt) = @_;

    plog('DEBUG', "building the chroot with "
			. join(', ', @{$opt->{packages}}));

    sudo($run, $config, "--mkdir", "-p", "$tmp_chroot/dev/pts",
		"$tmp_chroot/etc/sysconfig", "$tmp_chroot/proc",
	        "$tmp_chroot/var/lib/rpm");

    #system(qq($sudo sh -c "echo 127.0.0.1 localhost > $tmp_chroot/etc/hosts"));
    # warly some program perform a gethostbyname(hostname) and in the cluster the 
    # name are not resolved via DNS but via /etc/hosts
    sudo($run, $config, '--cp', "/etc/hosts", "$tmp_chroot/etc/");
    sudo($run, $config, '--cp', "/etc/resolv.conf", "$tmp_chroot/etc/");

    # install chroot
    my $urpmi = $run->{urpmi};

    if ($urpmi->{use__urpmi_root}) {
	if (!$urpmi->add_media__urpmi_root($tmp_chroot, $config->{base_media})) {
	    plog('ERROR', "urpmi.addmedia --urpmi-root failed");
	    return 0;
	}
    }
    $urpmi->set_command($tmp_chroot);

    # (blino) install meta-task first for prefer.vendor.list to be used
    foreach my $packages ([ 'meta-task' ], $opt->{packages}) {
        if (!$urpmi->install_packages(
            "chroot",
            $tmp_chroot,
            $run->{local_spool},
            {},
            'initialize',
            "[ADMIN] creation of initial chroot failed on $run->{my_arch}",
            { maintainer => $config->{admin} },
            @$packages
        )) {
            plog('ERROR', "Failed to install initial packages during chroot creation.");
            return 0;
        }
    }

    # <mrl> URPMI saying ok or not, we check this anyway. So that's why
    # it's outside the else.
    if (! -f "$tmp_chroot/usr/bin/rpmbuild") {
	plog(1, "ERROR: rpm-build is missing!");
	return 0;
    }

    # remove files used by --urpmi-root
    sudo($run, $config, "--rm", "$tmp_chroot/etc/urpmi/urpmi.cfg");
    sudo($run, $config, "--rm", "$tmp_chroot/var/lib/urpmi/*");

    system("rpm -qa --root $tmp_chroot --qf '\%{NAME}-\%{VERSION}-\%{RELEASE}.\%{ARCH}\n' | sort > $tmp_chroot/tmp/qa");
    sudo($run, $config, "--cp", "$tmp_chroot/tmp/qa", "$tmp_chroot/var/log/qa");
    unlink("$tmp_chroot/tmp/qa");

    sudo($run, $config, "--mkdir", "$tmp_chroot/etc/skel/rpm/$_")
      foreach "", qw(RPMS BUILD SPECS SRPMS SOURCES tmp);

    #
    # CM: Choose a sub-500 uid to prevent collison with $luser
    #
    sudo($run, $config, "--useradd", $tmp_chroot, 'builder', 499);

    # FIXME: <mrl> Be careful! Damn ugly hack right below!
    sudo($run, $config, "--rm", "$tmp_chroot/var/lib/rpm/__db*");
    sudo($run, $config, "--umount", "$tmp_chroot/proc");
    sudo($run, $config, "--umount", "$tmp_chroot/dev/pts");
    if ($run->{icecream}) {
	sudo($run, $config, "--umount", "$tmp_chroot/var/cache/icecream");
    }
    if (-d "$tmp_chroot/urpmi_medias/") {
	sudo($run, $config, "--umount", "$tmp_chroot/urpmi_medias");
    }
    return sudo($run, $config, "--tar", $chroot_tar, $tmp_chroot);
}

sub check_build_chroot {
    my ($chroot, $chroot_tar, $run, $config) = @_;

    check_chroot($chroot, $chroot_tar, $run, $config,
		{ packages => $config->{basesystem_packages} });
}

sub check_chroot {
    my ($chroot, $chroot_tar, $run, $config, $opt) = @_;

    plog('DEBUG', "checking basesystem tar");
    
    my (@stat) = stat $chroot_tar;

    if (time -$stat[9] > 604800) {
	plog('WARN', "chroot tarball too old, force rebuild");
	sudo($run, $config, '--rm', '-r', $chroot, $chroot_tar);
    }
    create_chroot($chroot, $chroot_tar, $run, $config, $opt);
}

1;
