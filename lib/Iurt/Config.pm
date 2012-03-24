package Iurt::Config;

use base qw(Exporter);
use RPM4::Header;
use Data::Dumper;
use MDK::Common;
use Iurt::Util qw(plog);
use strict;
use Sys::Hostname;

our @EXPORT = qw(
    config_usage
    config_init
    get_date
    dump_cache
    dump_cache_par
    init_cache
    get_maint
    get_date
    get_prefix
    get_author_email
    check_arch
    check_noarch
    get_package_prefix
    %arch_comp
);

our %arch_comp = (
    'i586' => { 'i386' => 1, 'i486' => 1, 'i586' => 1 },
    'i686' => { 'i386' => 1, 'i486' => 1, 'i586' => 1, 'i686' => 1 },
    'x86_64' => { 'x86_64' => 1 },
    'ppc' => { 'ppc' => 1 },
    'ppc64' => { 'ppc' => 1, 'ppc64' => 1 },
    'armv5tejl' => { 'armv5tl' => 1 },
    'armv5tel' => { 'armv5tl' => 1 },
    'armv5tl' => { 'armv5tl' => 1 },
    'armv7l' => { 'armv5tl' => 1 },
);


=head2 config_usage($config_usage, $config)

Create an instance of a class at runtime.
I<$config_usage> is the configuration help,
I<%config> is the current configuration values
Return true.

=cut

sub config_usage {
    my ($config_usage, $config) = @_;
	print "
	
	Iurt configuration keywords:
	
";
    $Data::Dumper::Indent = 0;
    $Data::Dumper::Terse = 1;
    foreach my $k (sort keys %$config_usage) {
	print "	$k: $config_usage->{$k}{desc} 
			default: ", Data::Dumper->Dump([ $config_usage->{$k}{default} ]), ", current: ", Data::Dumper->Dump([ $config->{$k} ]), "\n";
    }
    print "\n\n";
}

=head2 config_init($config_usage, $config, $rung)

Create an instance of a class at runtime.
I<$config_usage> is the configuration help,
I<%config> is the current configuration values
I<%run> is the current running options
Return true.

=cut

sub config_init {
    my ($config_usage, $config, $run) = @_;
    
    foreach my $k (keys %$config_usage) {
	ref $config_usage->{$k}{default} eq 'CODE' and next;
	$config->{$k} ||= $run->{config}{$k} || $config_usage->{$k}{default};
    }
    # warly 20061107
    # we need to have all the default initialised before calling functions, so this
    # cannot be done in the same loop
    foreach my $k (keys %$config_usage) {
	ref $config_usage->{$k}{default} eq 'CODE' or next;
	my $a = $config_usage->{$k}{default}($config, $run);
	$config->{$k} ||= $run->{config}{$k} || $a;
    }
}


=head2 get_date($shift)

Create a string based on the current date and time
I<$shift> number of second to shift the date
Return date-time and date

=cut

sub get_date {
    my ($o_shift) = @_;
    my ($sec, $min, $hour, $mday, $mon, $year) = gmtime(time() - $o_shift);
    $year += 1900;
    my $fulldate = sprintf "%4d%02d%02d%02d%02d%02d", $year, $mon+1, $mday, $hour, $min, $sec;
    my $daydate = sprintf "%4d%02d%02d", $year, $mon+1, $mday;
    $fulldate, $daydate;
}

sub get_prefix {
    my ($luser) = @_;
    my $hostname = hostname();
    my ($fulldate) = get_date();
    my ($host) = $hostname =~ /([^.]*)/;
    join('.', $fulldate, $luser, $host, $$) . '_';
}

sub get_package_prefix {
    my ($rpm) = @_;
    my ($prefix1) = $rpm =~ /^(\d{14}\.\w+\.\w+\.\d+)_/;
    my ($prefix2) = $rpm =~ /^(\@\d+:)/;
    "$prefix1$prefix2";
}
=head2 init_cache($run, $config)

Create a string based on the current date and time
I<%run> is the current running options
I<%config> is the current configuration values
Initialize the cache

=cut

sub init_cache {
    my ($run, $config, $empty) = @_;
    my $program_name = $run->{program_name};
    my $cachefile = "$config->{cache_home}/$program_name.cache";
    my $cache;
    if (-f $cachefile) {
	plog('DEBUG', "loading cache file $cachefile");
	$cache = eval(cat_($cachefile)) or print "FATAL $program_name: could not load cache $cachefile ($!)\n";
    } else {
	$cache = $empty;
    }
    $run->{cachefile} = $cachefile;
    $run->{cache} = $cache;
    $cache;
}

=head2 dump_cache($run, $config)

Create a string based on the current date and time
I<%run> is the current running options
Dump the cache

=cut

sub dump_cache {
    my ($run) = @_;
    my $program_name = $run->{program_name};
    my $filename = $run->{cachefile};
    my $cache = $run->{cache};
    my $daydate = $run->{daydate};
    open my $file, ">$filename.tmp.$daydate" or die "FATAL $program_name dump_cache: cannot open $filename.tmp";
    $Data::Dumper::Indent = 1;
    $Data::Dumper::Terse = 1;
    print $file Data::Dumper->Dump([ $cache ], [ "cache" ]);
    # flock does not work on network files and lockf seems to fail too
    plog('DEBUG', "locking to dump the cache in $filename");
    if (-f "$filename.lock") {
	plog('ERROR', 'ERROR: manual file lock exist, do not save the cache');
    } else {
	open my $lock, ">$filename.lock";
	print $lock $$;
	close $lock;
	unlink $filename;
	link "$filename.tmp.$daydate", $filename;
	unlink "$filename.lock";
    }
}

# FIXME need to merge with the simpler dump_cache
sub dump_cache_par {
    my ($run) = @_;
    my $filename = $run->{cachefile};
    my $cache = $run->{cache};
    my $daydate = $run->{daydate};

    # Right now there are no mechanism of concurrent access/write to the cache. There is 
    # on global lock for one iurt session. A finer cache access would allow several iurt running
    # but the idea is more to have a global parrallel build than several local ones.
    return if $run->{debug} || !$run->{use_cache};
    open my $file, ">$filename.tmp.$daydate" or die "FATAL iurt dump_cache: cannot open $filename.tmp";
    if ($run->{concurrent_run}) {
	plog('DEBUG', "merging cache");
	my $old_cache;
	if (-f $filename) {
	    plog('DEBUG', "loading cache file $filename");
	    $old_cache = eval(cat_($filename));

	    foreach my $k ('rpm_srpm', 'failure', 'queue', 'needed', 'warning', 'buildrequires') {
		foreach my $rpm (%{$old_cache->{$k}}) {
		    $cache->{$k}{$rpm} ||= $old_cache->{$k}{$rpm};
		}
	    }
	}
	#  $cache = { rpm_srpm => {}, failure => {}, queue => {}, warning => {}, run => 1, needed => {} }
    }
    $Data::Dumper::Indent = 1;
    $Data::Dumper::Terse = 1;
    print $file Data::Dumper->Dump([ $cache ], [ "cache" ]);
    # flock does not work on network files and lockf seems to fail too
    my $status = 1; #File::lockf::lock($file);
    if (!$status) {
	unlink $filename;
	link "$filename.tmp.$daydate", $filename;
	# FIXME: File::lockf isn't use(d) or require(d) and isn't even in the distro
	File::lockf::ulock($file);
    } else {
	plog('WARN', "WARNING: locking the cache file $filename failed (status $status $!), try to lock manually");
	if (-f "$filename.lock") {
	    plog('ERROR', "ERROR: manual file lock exist, do not save the cache");
	} else {
	    open my $lock, ">$filename.lock";
	    print $lock $$;
	    close $lock;
	    unlink $filename;
	    link "$filename.tmp.$daydate", $filename;
	    unlink "$filename.lock";
	}
    }
}

sub get_maint {
    my ($run, $srpm) = @_;
    my ($srpm_name) = $srpm =~ /(.*)-[^-]+-[^-]+\.[^.]+$/;
    $srpm_name ||= $srpm;
    if ($run->{maint}{$srpm}) {
	return $run->{maint}{$srpm}, $srpm_name;
    }
    my $maint = `GET 'http://maintdb.mageia.org/$srpm_name'`;
    chomp $maint;
    $run->{maint}{$srpm} = $maint;
    $maint, $srpm_name;
}

sub get_author_email {
    my ($user) = @_;
    my $authoremail = $user . ' <' . $user . '>';

    return $authoremail;
}

sub check_noarch {
    my ($rpm) = @_;
    my $hdr = RPM4::Header->new($rpm);

    # Stupid rpm doesn't return an empty list so we must check for (none)

    my ($build_archs) = $hdr->queryformat('%{BUILDARCHS}');

    if ($build_archs ne '(none)') {
	($build_archs) = $hdr->queryformat('[%{BUILDARCHS} ]');
	my @list = split ' ', $build_archs;
	return 1 if member('noarch', @list);
    }

    return 0;
}

sub check_arch {
    my ($rpm, $arch) = @_;
    my $hdr = RPM4::Header->new($rpm);

    # Stupid rpm doesn't return an empty list so we must check for (none)

    my ($exclusive_arch) = $hdr->queryformat('%{EXCLUSIVEARCH}');

    if ($exclusive_arch ne '(none)') {
	($exclusive_arch) = $hdr->queryformat('[%{EXCLUSIVEARCH} ]');
	my @list = split ' ', $exclusive_arch;
	return 0 unless any { $arch_comp{$arch}{$_} } @list;
    }

    my ($exclude_arch) = $hdr->queryformat('[%{EXCLUDEARCH} ]');

    if ($exclude_arch ne '(none)') {
	($exclude_arch) = $hdr->queryformat('[%{EXCLUDEARCH} ]');
	my @list = split ' ', $exclude_arch;
	return 0 if member($arch, @list);
    }

    return 1;
}

1;
