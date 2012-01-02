package Iurt::Mail;

use strict;
use MIME::Words qw(encode_mimewords);
use base qw(Exporter);

our @EXPORT = qw(
    sendmail
);

sub expand_email {
	my($email, $config) = @_;
	return $email unless $config->{email_domain};
	my $name = "";
	my $addr = $email;
	if ($email =~ /^(.*)<(.*)>$/) {
		$name = $1;
		$addr = $2;
	}
	if ($addr =~ /@/) {
		return $email;
	}
	return "$name<$addr\@$config->{email_domain}>";
}

sub sendmail {
	my ($to, $cc, $subject, $text, $from, $debug, $config) = @_;
	do { print "Cannot find sender-email-address [$to]\n"; return } unless defined($to);
	my $MAIL;
	if (!$debug) { open $MAIL,  "| /usr/sbin/sendmail -t" or return } else { open $MAIL,  ">&STDOUT" or return }
	$to = expand_email($to, $config);
	my $sender = encode_mimewords($to);
	$subject = encode_mimewords($subject);
	print $MAIL "To: $sender\n";
	if ($cc) {
		$cc = expand_email($cc, $config);
		$cc = encode_mimewords($cc);
		print $MAIL "Cc: $cc\n"
	}
	print $MAIL "From: $from\n";
	print $MAIL "Subject: $subject\n";
	print $MAIL "\n";
	print $MAIL $text; 
	close($MAIL);
}

1
