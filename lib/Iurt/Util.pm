package Iurt::Util;

use base qw(Exporter);
use strict;

our @EXPORT = qw(
    plog_init
    plog
    pdie
    ssh_setup
    ssh
    sout
    sget
    sput
);

my ($plog_name, $plog_file, $plog_level, $plog_color);

=head2 LOG HELPERS

=over 8

=item plog_init($program_name, $logfile)

=item plog_init($program_name, $logfile, $level)

Initialize plog with the program name, log file and optional log level.
If not specified, the log level will be set to 9999.

=cut

my %plog_ctr = (
	red     => "\x1b[31m",
	green   => "\x1b[32m",
	yellow  => "\x1b[33m",
	blue    => "\x1b[34m",
	magenta => "\x1b[35m",
	cyan    => "\x1b[36m",
	grey    => "\x1b[37m",
	bold	=> "\x1b[1m",
	normal  => "\x1b[0m",
);

my @plog_prefix = (
	"",
	"E: ",
	"W: ",
	"*: ",
	"F: ",
	"O: ",
	"N: ",
	"I: ",
	"D: ",
);

my %plog_level = (
	NONE	=> 0,
	ERROR	=> 1,
	WARN	=> 2,
	MSG	=> 3,
	FAIL	=> 4,
	OK	=> 5,
	NOTIFY	=> 6,
	INFO	=> 7,
	DEBUG	=> 8,
);

sub plog_init {
        $plog_name = shift;
        $plog_file = shift;
        $plog_level = shift @_ || 9999;
        $plog_color = shift @_ || 0;

	$plog_level = 9999 if $ENV{PLOG_DEBUG};

	$plog_color = 0 unless -t fileno $plog_file;

	foreach (@plog_prefix) { $_ .= "[$plog_name] " }

	if ($plog_color) {
		$plog_prefix[1] .= "$plog_ctr{bold}$plog_ctr{red}";
		$plog_prefix[2] .= "$plog_ctr{bold}$plog_ctr{yellow}";
		$plog_prefix[3] .= $plog_ctr{bold};
		$plog_prefix[4] .= $plog_ctr{red};
		$plog_prefix[5] .= $plog_ctr{green};
		$plog_prefix[6] .= $plog_ctr{cyan};
		$plog_prefix[8] .= $plog_ctr{yellow};
	}

	1;
}

=item plog($message)

=item plog($level, @message)

Print a log message in the format "program: I<message>\n" to the log
file specified in a call to plog_init(). If a level is specified,
the message will be printed only if the level is greater or equal the
level set with plog_init().

=back

=cut

sub plog {
	my $level = $#_ ? shift : 'INFO';
	$level = $plog_level{$level};
	my ($p, $e) = ($plog_prefix[$level], ($plog_color ? $plog_ctr{normal} : ""));
	
	print $plog_file "$p@_$e\n" if $plog_level >= $level;
}

sub pdie {
	plog('ERROR', "@_");
	die $@;
}

=head2 SSH HELPERS

=over 8

=item ssh_setup($options, $user, $host)

Set up ssh connections with the specified options, user and remote
host. Return an ssh handle to be used in ssh-based operations.

=cut

sub ssh_setup {
	my $opt = shift;
	my $user = shift;
	my $host = shift;
	my @conf = ($opt, $user, $host);
	\@conf;
}

=item ssh($handle, @commmand)

Open an ssh connection with parameters specified in ssh_setup() and
execute I<@command>. Return the command execution status.

=cut

# This is currently implemented using direct calls to ssh/scp because.
# according to Warly's comments in ulri, using the perl SSH module
# gives us some performance problems

sub ssh {
	my $conf = shift;
	my ($opt, $user, $host) = @$conf;
	system("ssh $opt -x $user\@$host @_");
}

=item sout($handle, @commmand)

Open an ssh connection with parameters specified in ssh_setup() and
execute I<@command>. Return the command output.

=cut

sub sout {
	my $conf = shift;
	my ($opt, $user, $host) = @$conf;
	`ssh $opt -x $user\@$host @_ 2>/dev/null`;
}

=item sget($handle, $from, $to)

Get a file using scp, from the remote location I<$from> to the
local location I<$to>, using host and user specified in ssh_setup().

=cut

sub sget {
	my $conf = shift;
	my ($_opt, $user, $host) = @$conf;
	system('scp', '-q', '-rc', 'arcfour', "$user\@$host:$_[0]", $_[1]);
}

=item sput($handle, $from, $to)

Send a file using scp, from a local location I<$from> to the remote
location I<$to>, using host and user specified in ssh_setup().

=back

=cut

sub sput {
	my $conf = shift;
	my ($_opt, $user, $host) = @$conf;
	system('scp', '-q', '-rc', 'arcfour', $_[0], "$user\@$host:$_[1]");
}

=back

=cut

1;
