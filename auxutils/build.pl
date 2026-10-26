#!/usr/bin/perl
#
# build.pl -- render blog/*.md to static blog/*.html via pandoc.
#
# The .md files in blog/ are the single source of truth. Each file is
# converted with pandoc and wrapped in a small template (milligram CSS,
# page title, back-link to the homepage); the result is written next
# to the source file.
#
# Only core Perl modules are used; the sole external dependency is the
# pandoc binary (see auxutils/install.pl).
#
# Usage:
#   auxutils/build.pl [ROOT]
#
# ROOT defaults to the parent directory of this script's directory,
# i.e. the repository root.

use strict;
use warnings;
use FindBin;
use File::Basename qw(dirname);
use IPC::Open3;
use Symbol qw(gensym);

my $root = defined $ARGV[0] ? $ARGV[0] : dirname($FindBin::Bin);

my $blog_dir = "$root/blog";
die "build.pl: no blog directory at $blog_dir\n" unless -d $blog_dir;

my @md_files = glob("$blog_dir/*.md");
die "build.pl: no .md files found in $blog_dir\n" unless @md_files;

# Template for a rendered post. Placeholders: __TITLE__, __CONTENT__.
my $template = <<'HTML';
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>__TITLE__</title>
  <link rel="stylesheet" href="../milligram.min.css">
  <style>
    pre { overflow-x: auto; }
    .home-link { display: inline-block; margin-bottom: 1.5rem; }
  </style>
</head>
<body>
<div class="container">
  <a class="home-link" href="../index.html">&larr; Home</a>
  <div id="content">
__CONTENT__
  </div>
</div>
</body>
</html>
HTML

# Escape a string for safe use inside an HTML tag.
sub html_escape {
    my ($s) = @_;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    return $s;
}

for my $md (@md_files) {
    my $html = $md;
    $html =~ s/\.md$/.html/;

    # Title = first non-empty line of the source (our posts lead with
    # a setext H1).
    open my $in, '<', $md or die "build.pl: cannot read $md: $!\n";
    my $title;
    while (my $line = <$in>) {
        if ($line =~ /\S/) {
            $title = $line;
            last;
        }
    }
    close $in;
    die "build.pl: $md has no title line\n" unless defined $title;
    chomp $title;

    my $err      = gensym;
    my $pid      = open3(my $in_pipe, my $out, $err,
                          'pandoc', '-f', 'markdown', '-t', 'html',
                          '--no-highlight', $md);
    close $in_pipe;
    my $body = do { local $/; <$out> };
    waitpid $pid, 0;
    my $status = $? >> 8;
    if ($status != 0) {
        my $errmsg = do { local $/; <$err> };
        die "build.pl: pandoc failed on $md (exit $status):\n$errmsg\n";
    }

    my $page = $template;
    my $safe_title = html_escape($title);
    $page =~ s/__TITLE__/$safe_title/;
    $page =~ s/__CONTENT__/$body/;

    open my $outfh, '>', $html or die "build.pl: cannot write $html: $!\n";
    print {$outfh} $page;
    close $outfh;

    print "rendered $md -> $html\n";
}

print "done: ", scalar(@md_files), " file(s)\n";
