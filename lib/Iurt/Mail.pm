package Iurt::Mail;

use strict;
use MIME::Words qw(encode_mimewords);
use base qw(Exporter);

our @EXPORT = qw(
    sendmail
);

sub sendmail {
	my ($to, $cc, $subject, $text, $from, $debug) = @_;
	do { print "Cannot find sender-email-address [$to]\n"; return } unless defined($to);
	my $MAIL;
	if (!$debug) { open $MAIL,  "| /usr/sbin/sendmail -t" or return } else { open $MAIL,  ">&STDOUT" or return }
	my $sender = encode_mimewords($to);
	$subject = encode_mimewords($subject);
	print $MAIL "To: $sender\n";
	if ($cc) { $cc = encode_mimewords($cc); print $MAIL "Cc: $cc\n" }
	print $MAIL "From: $from\n";
	print $MAIL "Subject: $subject\n";
	print $MAIL "\n";
	print $MAIL $text; 
	close($MAIL);
}

1
