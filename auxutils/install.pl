#!/usr/bin/perl
#
# install.pl -- install build dependencies for auxutils/build.pl.
#
# Targets RHEL 9/10 family distributions (RHEL, CentOS, AlmaLinux,
# Rocky Linux). Installs pandoc via dnf. build.pl itself only uses
# core Perl modules, so no CPAN dependencies are required.
#
# Usage:
#   sudo auxutils/install.pl

use strict;
use warnings;

if ($> != 0) {
    die "install.pl: must be run as root (try: sudo $0)\n";
}

my $release_file = '/etc/redhat-release';
die "install.pl: $release_file not found -- this script targets "
  . "RHEL 9/10 family systems (dnf-based)\n"
  unless -f $release_file;

open my $rh, '<', $release_file
  or die "install.pl: cannot read $release_file: $!\n";
my $release = do { local $/; <$rh> };
close $rh;
$release =~ s/\s+$//;
print "install.pl: detected: $release\n";

system('dnf', '--version') == 0
  or die "install.pl: dnf not found or not functional\n";

my @pkgs = qw(pandoc);

# Only install packages that are missing.
my @missing;
for my $pkg (@pkgs) {
    push @missing, $pkg if system('dnf', 'list', 'installed', $pkg) != 0;
}

if (@missing) {
    print "install.pl: installing: @missing\n";
    system('dnf', 'install', '-y', @missing) == 0
      or die "install.pl: dnf install failed -- if pandoc is not in "
           . "your enabled repos, enable the extras/appstream repo "
           . "or install pandoc manually\n";
}
else {
    print "install.pl: all dependencies already installed\n";
}

system('pandoc', '--version') == 0
  or die "install.pl: pandoc verification failed\n";

print "install.pl: OK\n";
