# Site Deployment

Target: test server 10.0.0.143 (AlmaLinux 10.2), web server nginx,
static blog rendered at deploy time by pandoc.

## How it works

- `blog/*.md` are the single source of truth (stored in git).
- `auxutils/build.pl` renders each to `blog/*.html` via pandoc, wrapped
  in a template (milligram CSS, title, back-link). Generated `.html`
  files are gitignored.
- nginx serves everything; `.php` goes through php-fpm (the current
  pages contain no PHP, but the handler is in place).
- The server has NO access to the git repo, so deploys are
  rsync + remote build (`auxutils/deploy.sh`).

## One-time server setup (performed 2026-10-25)

All steps as root unless noted.

1. Install packages:

       dnf install -y nginx php-fpm tar

   - nginx 1.26.3, php-fpm 8.3.36 from base repos.
   - `tar` was missing on the minimal install (needed for the initial
     tar-pipe sync).
   - pandoc is NOT in base repos -- it comes from EPEL (epel-release
     was already enabled on this box). Pandoc 3.1.11.1 installed.

2. Create the web root, owned by the deploy user (chris) so day-2
   deploys don't need root:

       mkdir -p /var/www/site
       chown chris:chris /var/www/site

3. Initial code sync from the dev machine (server has no git access).
   rsync was not available on the dev machine at first, so a tar pipe
   was used:

       tar -C ~/site --exclude=.git -cf - . | \
           ssh root@10.0.0.143 'tar -C /var/www/site -xf -'

4. Install build dependencies with the repo's own script (this is what
   pulls pandoc from EPEL):

       perl /var/www/site/auxutils/install.pl

5. Install the nginx server block:

       cp auxutils/nginx-site.conf /etc/nginx/conf.d/site.conf

   (The repo copy is canonical; it contains the PHP fastcgi location
   with the SCRIPT_FILENAME fix.)

6. Disable the stock default server in /etc/nginx/nginx.conf (it
   shadows conf.d blocks for IP-address requests):

       perl auxutils/disable-default-server.pl

   - Backs up to /etc/nginx/nginx.conf.orig, then comments out the
     stock `server { listen 80; ... root /usr/share/nginx/html; }`
     block. Refuses to run if the block text isn't found.

7. Validate and start services:

       nginx -t
       systemctl enable --now php-fpm nginx

8. First build (as chris):

       perl /var/www/site/auxutils/build.pl /var/www/site

9. Verify:

       curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.143/
       curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.143/resume.php
       curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.143/blog/php-sigsegv.html

   All three returned 200.

No firewall changes were needed: firewalld is not installed/active on
the test server. SELinux is disabled on the test server; if it is ever
enabled, run `restorecon -Rv /var/www/site` after a sync.

## Day-2 deploy (from the dev machine)

    auxutils/deploy.sh              # defaults to chris@10.0.0.143
    auxutils/deploy.sh user@host    # other targets

What it does: rsync -avz --delete --exclude .git of the repo working
tree into /var/www/site, then runs build.pl on the server. No server
reloads needed -- output is static.

Dev machine requirements: rsync (e.g. `apt install rsync` /
`dnf install rsync`) and ssh key access as the deploy user.

## File map

| Path                          | Purpose                                  |
|-------------------------------|------------------------------------------|
| auxutils/build.pl             | md -> html build (core Perl + pandoc)    |
| auxutils/install.pl           | server dependency install (pandoc/EPEL)  |
| auxutils/deploy.sh            | rsync + remote build                     |
| auxutils/nginx-site.conf      | nginx server block (canonical copy)      |
| auxutils/disable-default-server.pl | one-shot: disable stock nginx default |
| blog/*.md                     | post sources (in git)                    |
| blog/*.html                   | rendered posts (gitignored, on server)   |
| milligram.min.css             | page styling                             |

## Gotchas hit during setup (so you don't re-hit them)

- `include fastcgi_params` does NOT set SCRIPT_FILENAME (that lives in
  fastcgi.conf). Without `fastcgi_param SCRIPT_FILENAME
  $document_root$fastcgi_script_name;` every .php request 404s from
  php-fpm.
- The stock nginx.conf default server must be disabled or your
  conf.d block silently loses IP-address requests to it.
- pandoc on RHEL/Alma comes from EPEL, not the base repos.
- pandoc 3.x HTML output includes server-side syntax highlighting and
  line-number spans by default; build.pl passes --no-highlight to keep
  the static pages lean.
- EL10 nginx.conf's default server block has no "# Default server."
  comment header (older RHEL versions do) -- the disable script
  matches the block text, not a comment.
