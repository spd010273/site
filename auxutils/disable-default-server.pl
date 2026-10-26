#!/usr/bin/perl
#
# disable-default-server.pl -- one-shot helper for initial server setup.
#
# Comments out the stock default server block in /etc/nginx/nginx.conf
# (RHEL/Alma family layout, nginx 1.2x) so that
# /etc/nginx/conf.d/site.conf becomes the effective server. A backup is
# written to /etc/nginx/nginx.conf.orig first.
#
# Usage (as root on the target server):
#   perl disable-default-server.pl [nginx.conf]

use strict;
use warnings;

my $conf = $ARGV[0] // '/etc/nginx/nginx.conf';
die "no such file: $conf\n" unless -f $conf;

open my $fh, '<', $conf or die "cannot read $conf: $!\n";
my $text = do { local $/; <$fh> };
close $fh;

my $block = <<"BLOCK";
    server {
        listen       80;
        listen       [::]:80;
        server_name  _;
        root         /usr/share/nginx/html;

        # Load configuration files for the default server block.
        include /etc/nginx/default.d/*.conf;
    }
BLOCK

die "default server block not found in $conf -- already disabled, or "
  . "layout differs; inspect the file manually\n"
  unless index($text, $block) >= 0;

# Comment out the block, one line at a time.
my $commented = $block;
$commented =~ s/^/# /mg;

my $replacement = "# --- default server block disabled by site deploy "
                . "(see /etc/nginx/conf.d/site.conf) ---\n"
                . $commented;

$text =~ s/\Q$block\E/$replacement/;

system('cp', $conf, "$conf.orig") == 0
  or die "backup of $conf failed: $!\n";

open my $out, '>', $conf or die "cannot write $conf: $!\n";
print {$out} $text;
close $out;

print "disabled default server block in $conf (backup: $conf.orig)\n";
