package Iurt::File;

use base qw(Exporter);
use Iurt::Util qw(plog);
use strict;

our @EXPORT = qw(
    check_upload_tree 
);

=head2 config_usage($config_usage, $config)

Create an instance of a class at runtime.
I<$config_usage> is the configuration help,
I<%config> is the current configuration values
Return true.

=cut

sub check_upload_tree {
    my ($todo, $func, $post) = @_;

    # Squash double slashes for cosmetics
    $todo =~ s!/+!/!g;

    opendir my $dir, $todo;
    plog('INFO', "check dir: $todo");

    foreach my $f (readdir $dir) {
	$f =~ /^\.{1,2}$/ and next;
	if (-d "$todo/$f") {
	    plog('DEBUG', "checking target $todo/$f");
	    opendir my $target_dir, "$todo/$f";

	    foreach my $m (readdir $target_dir) {
		$m =~ /^\.{1,2}$/ and next;
		if (-d "$todo/$f/$m") {
		    plog('DEBUG', "checking media $todo/$f/$m");
		    opendir my $media_dir, "$todo/$f/$m";

		    foreach my $s (readdir $media_dir) {
			$s =~ /^\.{1,2}$/ and next;
			if (-d "$todo/$f/$m/$s") {
			    if ($func) {
				opendir my $submedia_dir, "$todo/$f/$m/$s";
				foreach my $r (readdir $submedia_dir) {
				    $r =~ /^\.{1,2}$/ and next;
				    $func->($todo, $f, $m, $s, $r);
				}
			    }
			    # cleaning
			    if ($post) {
				opendir my $submedia_dir, "$todo/$f/$m/$s";
				foreach my $r (readdir $submedia_dir) {
				    $r =~ /^\.{1,2}$/ and next;
				    $post->($todo, $f, $m, $s, $r);
				}
			    }
			} else {
			    # may need to check also here for old target
			}
		    }
		}
	    }
	}
    }
}
 
