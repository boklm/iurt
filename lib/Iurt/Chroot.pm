package Iurt::Chroot;

use strict;
use base qw(Exporter);
use MDV::Distribconf::Build;
use MDK::Common;
use Iurt::Process qw(sudo);
use Iurt::Config qw(dump_cache_par);
use Iurt::Util qw(plog);
# perl_checker: use Iurt::Urpmi
use File::Temp 'mktemp';
use File::Path 'mkpath';
use urpm;

our @EXPORT = qw(
    add_local_user
    clean_and_build_chroot
    clean_chroot
    create_build_chroot
    create_temp_chroot
    dump_rpmmacros
    remove_chroot
);
    
my $sudo = '/usr/bin/sudo';

=head2 clean_chroot($chroot, $run, $config)

Create or clean a chroot
I<$chroot> chroot path
I<$run> is the running environment
Return true.

=cut

sub clean_chroot {
    my ($chroot, $run, $config) = @_;

    plog('DEBUG', "clean chroot");
    if (-d $chroot) {
        _clean_mounts($run, $config, $chroot);

	# Do not run rm if there is something still mounted there
	open(my $FP, "/proc/mounts") or die $!;
	my @list = grep { /$chroot/ } <$FP>;
	close($FP);
	if (@list) {
	    # Still referenced
	    plog('ERROR', "Not cleaning chroot (mount points still in use)");
	    return 1;
	}

	delete_chroot($run, $config, $chroot);
    }
    0;
}


=head2 clean_and_build_chroot($chroot, $chroot_ref, $run, $config)

Create or clean a chroot
I<$chroot> chroot path
I<$run> is the running environment
Return true.

=cut


sub clean_and_build_chroot {
    my ($chroot, $chroot_ref, $run, $config) = @_;
    clean_chroot($chroot, $run, $config) and return 1;

    if (!create_build_chroot($chroot, $chroot_ref, $run, $config)) {
	plog('ERROR', "Failed to create chroot");
        return;
    }

    if (!dump_rpmmacros($run, $config, "$chroot/home/builder/.rpmmacros")) {
	plog('ERROR', "Failed to dump macros");
	return;
    }
    if (!sudo($config, '--bindmount', "/proc", "$chroot/proc")) {
	plog('ERROR', "Failed to mount proc");
	return;
    }
    if (!sudo($config, '--bindmount', "/dev/pts", "$chroot/dev/pts")) {
	plog('ERROR', "Failed to mount dev/pts");
	sudo($config, "--umount", "$chroot/proc");
	return;
    }
    if (system("$sudo mount none -t tmpfs $chroot/dev/shm")) {
	plog('WARNING', "Failed to mount /dev/shm");
    }
    if ($run->{icecream}) {
	system("$sudo mkdir -p $chroot/var/cache/icecream");
	if (!sudo($config, '--bindmount', "/var/cache/icecream", "$chroot/var/cache/icecream")) {
	    plog('ERROR', "Failed to mount var/cache/icecream");
            _clean_mounts($run, $config, $chroot);
	    return;
	}
    }

    if ($run->{additional_media} && $run->{additional_media}{repository}) {
        _setup_additional_media($run, $config, $chroot) or return;
    }
    1;
}

sub _setup_additional_media {
    my ($run, $config, $chroot) = @_;
    my $rep = $run->{additional_media}{repository};

    return 1 if !urpm::is_local_url($rep);

    my $mount_point = "$chroot/urpmi_medias";
    my $url = urpm::file_from_local_url($rep);
    sudo($config, '--mkdir', '-p', $mount_point);
    if (!sudo($config, '--bindmount', $url, $mount_point)) {
        plog('ERROR', "Failed to mount $url on $mount_point");
        _clean_mounts($run, $config, $chroot);
        return;
    }
    1;
}

sub _clean_mounts {
    my ($run, $config, $chroot) = @_;
    sudo($config, "--umount", "$chroot/proc");
    sudo($config, "--umount", "$chroot/dev/pts");
    sudo($config, "--umount", "$chroot/dev/shm");

    if ($run->{icecream}) {
        sudo($config, "--umount", "$chroot/var/cache/icecream");
    }

    if (-d "$chroot/urpmi_medias") {
        sudo($config, "--umount", "$chroot/urpmi_medias");
    }
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

    my $ret = sudo($config, '--cp', $tmpfile, $file);
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
	if (!sudo($config, "--useradd", $chroot_tmp, $luser, $uid)) {
	    plog('ERROR', "ERROR: setting userid $uid to $luser in " .
		"$chroot_tmp failed");
	    return;
	}
    } else {
	# the program has been launch as root, setting the home to /home/root for compatibility
	system($sudo, 'chroot', $chroot_tmp, 'usermod', '-d', "/home/$luser", '-u', $uid, '-o', '-l', $luser, 'root');
    }

    dump_rpmmacros($run, $config, "$chroot_tmp/home/$luser/.rpmmacros") or return;

    1;
}

sub create_temp_chroot {
    my ($run, $config, $chroot_tmp, $chroot_ref) = @_;

    plog("Install new chroot");
    plog('DEBUG', "... in $chroot_tmp");
    clean_and_build_chroot($chroot_tmp, $chroot_ref, $run, $config) or return;

    $chroot_tmp;
}

sub remove_chroot {
    my ($run, $config, $dir, $prefix) = @_;

    plog("Remove existing chroot");
    plog('DEBUG', "... dir $dir all $run->{clean_all} prefix $prefix");

    if ($run->{clean_all}) {
	opendir(my $chroot_dir, $dir);
	foreach (readdir $chroot_dir) {
	    next if !-d "$dir/$_" || /\.{1,2}/;
	    plog("cleaning old chroot for $_ in $dir");
	    clean_all_chroot_tmp($run, $config, "$dir/$_", $prefix);
	}
    } else {
	foreach my $user (@{$run->{clean}}) {
	    plog("cleaning old chroot for $user in $dir");
	    clean_all_chroot_tmp($run, $config, "$dir/$user", $prefix);
	}
    }
} 

sub clean_all_chroot_tmp {
    my ($run, $config, $chroot_dir, $prefix) = @_;

    plog(1, "cleaning all old chroot remaining dir in $chroot_dir");

    my $dir;
    if (!opendir $dir, $chroot_dir) { 
	plog("ERROR: can't open $chroot_dir ($!)");
	return;
    }
    foreach (readdir($dir)) {
	/$prefix/ or next;
	delete_chroot($run, $config, "$chroot_dir/$_");
    }
    closedir $dir;
}

sub delete_chroot {
    my ($run, $config, $chroot) = @_;

    _clean_mounts($run, $config, $chroot);

    plog(1, "cleaning $chroot");
    # Needs to be added to iurt_root_command
    # system("$sudo /sbin/fuser -k $chroot &> /dev/null");
    plog(1, "removing $chroot");
    if ($run->{storage} eq 'btrfs') {
	sudo($config, '--btrfs_delete', $chroot);
    } else {
        sudo($config, '--rm', '-r', $chroot);
    }
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

sub check_chroot_need_update {
    my ($tmp_chroot, $run) = @_;

    my $tmp_urpmi = mktemp("$tmp_chroot/tmp.XXXXXX");
    my @installed_pkgs = grep { !/^gpg-pubkey/ } chomp_(cat_("$tmp_chroot/var/log/qa"));
    my @available_pkgs = chomp_(`urpmq --urpmi-root $tmp_urpmi --use-distrib $run->{urpmi}{distrib_url} --list -f 2>/dev/null`);
    my @removed_pkgs = difference2(\@installed_pkgs, \@available_pkgs);

    rm_rf($tmp_urpmi);

    if (@installed_pkgs) {
        if (@removed_pkgs) {
            plog('DEBUG', "changed packages: @removed_pkgs");
            plog('NOTIFY', "Rebuilding chroot tarball");
            return 1;
        } else {
            plog('NOTIFY', "chroot tarball is already up-to-date");
	    return 0;
        }
    } else {
        plog('DEBUG', "can't open $tmp_chroot/var/log/qa");
        plog('ERROR', "can't check chroot, recreating");
        return 1;
    }
}

sub create_build_chroot {
    my ($chroot, $chroot_ref, $run, $config) = @_;
    my $ret = 0;
    if ($run->{storage} eq 'btrfs') {
        $ret = create_build_chroot_btrfs($chroot, $chroot_ref, $run, $config);
    } else {
        $ret = create_build_chroot_tar($chroot, $chroot_ref, $run, $config);
    }

    if ($ret) {
        my $urpmi = $run->{urpmi};
        if ($urpmi->{use__urpmi_root} && !$run->{chrooted_urpmi}) {
	    if (!$urpmi->add_media__urpmi_root($chroot, $config->{base_media})) {
	        plog('ERROR', "urpmi.addmedia --urpmi-root failed");
	        return;
	    }
        }
    }
    return $ret;
}

sub create_build_chroot_tar {
    my ($chroot, $chroot_tar, $run, $config) = @_;

    my $tmp_chroot = mktemp("$chroot.tmp.XXXXXX");
    my $rebuild;
    my $clean = sub {
	plog("Remove temporary chroot");
	sudo($config, '--rm', '-r', $tmp_chroot);
    };

    plog('NOTIFY', "creating chroot");

    mkdir_p($tmp_chroot);
    if (!-f $chroot_tar) {
        plog("rebuild chroot tarball");
        $rebuild = 1;
    } else {
        plog('DEBUG', "decompressing /var/log/qa from $chroot_tar in $tmp_chroot");
        sudo($config, '--untar', $chroot_tar, $tmp_chroot, "./var/log/qa");
        $rebuild = check_chroot_need_update($tmp_chroot, $run);
    }

    if ($rebuild) {
	sudo($config, '--rm', '-r', $chroot);
	if (!build_chroot($run, $config, $tmp_chroot)) {
	    plog('NOTIFY', "creating chroot failed.");
	    $clean->();
	    return;
	} 
	sudo($config, "--tar", $chroot_tar, $tmp_chroot);
	# This rename may fail if for example tmp chroots are in another FS
	# This does not matter as it will then be rm + untar
	rename $tmp_chroot, $chroot;
    }

    if (!-d $chroot) {
	plog('DEBUG', "recreate chroot $chroot");
	plog('NOTIFY', "recreate chroot");
	mkdir_p $chroot;
	sudo($config, '--untar', $chroot_tar, $chroot);
	plog('NOTIFY', "chroot recreated in $chroot_tar (live in $chroot)");
    }
    
    $clean->();

    1;
}

sub create_build_chroot_btrfs {
    my ($chroot, $chroot_ref, $run, $config) = @_;

    plog('NOTIFY', "creating btrfs chroot");

    if (check_chroot_need_update($chroot_ref, $run)) {
	sudo($config, '--btrfs_delete', $chroot_ref);
	if (!sudo($config, '--btrfs_create', $chroot_ref)) {
	    plog('ERROR', "creating btrfs subvolume failed.");
	    return;
	}
	if (!build_chroot($run, $config, $chroot_ref)) {
	    plog('ERROR', "creating chroot failed.");
	    sudo($config, '--btrfs_delete', $chroot_ref);
	    return;
	} 
    }

    sudo($config, '--btrfs_snapshot', $chroot_ref, $chroot);
}

sub build_chroot {
    my ($run, $config, $tmp_chroot) = @_;

    plog('DEBUG', "building the chroot with "
			. join(', ', @{$config->{basesystem_packages}}));

    sudo($config, "--mkdir", "-p", "$tmp_chroot/dev/pts", "$tmp_chroot/dev/shm",
		"$tmp_chroot/etc/sysconfig", "$tmp_chroot/proc",
	        "$tmp_chroot/var/lib/rpm");

    #system(qq($sudo sh -c "echo 127.0.0.1 localhost > $tmp_chroot/etc/hosts"));
    # warly some program perform a gethostbyname(hostname) and in the cluster the 
    # name are not resolved via DNS but via /etc/hosts
    sudo($config, '--cp', "/etc/hosts", "$tmp_chroot/etc/");
    sudo($config, '--cp', "/etc/resolv.conf", "$tmp_chroot/etc/");

    # install chroot
    my $urpmi = $run->{urpmi}; # perl_checker: $urpmi = Iurt::Urpmi->new

    if ($urpmi->{use__urpmi_root}) {
	if (!$urpmi->add_media__urpmi_root($tmp_chroot, $config->{base_media})) {
	    plog('ERROR', "urpmi.addmedia --urpmi-root failed");
	    return 0;
	}
    }
    $urpmi->set_command($tmp_chroot);

    # (blino) install meta-task first for prefer.vendor.list to be used
    foreach my $packages ([ 'meta-task' ], $config->{basesystem_packages}) {
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
    sudo($config, "--rm", "$tmp_chroot/etc/urpmi/urpmi.cfg");
    sudo($config, "--rm", "$tmp_chroot/var/lib/urpmi/*");

    # rpm is not running as root and cannot directly write to $tmp_chroot/var/log/qa
    system("rpm -qa --root $tmp_chroot --qf '\%{NAME}-\%{VERSION}-\%{RELEASE}.\%{ARCH}\n' | sort > $tmp_chroot/tmp/qa");
    sudo($config, "--cp", "$tmp_chroot/tmp/qa", "$tmp_chroot/var/log/qa");
    unlink("$tmp_chroot/tmp/qa");

    sudo($config, "--mkdir", "$tmp_chroot/etc/skel/rpm/$_")
      foreach "", qw(RPMS BUILD SPECS SRPMS SOURCES tmp);

    #
    # CM: Choose a sub-500 uid to prevent collison with $luser
    #
    sudo($config, "--useradd", $tmp_chroot, 'builder', 499);

    # FIXME: <mrl> Be careful! Damn ugly hack right below!
    sudo($config, "--rm", "$tmp_chroot/var/lib/rpm/__db*");
    _clean_mounts($run, $config, $tmp_chroot);

    1;
}

1;
