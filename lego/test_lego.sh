#!/bin/bash

# Sample script: exercises lego_cert.sh through its stages end-to-end for
# manual testing - init once (self-signed placeholder), run once (real
# certificate), then poll in a loop and renew once enough time has
# passed. This is the same shape a real main loop (e.g.
# domino-nrpc-proxy's entrypoint.sh) would use: wake up periodically,
# check whether it's time to act, act if so. "show" is called after every
# step so the certificate that's actually in DEPLOY_DIR at each point -
# placeholder, then real, then each renewal - is visible.
#
# lego_cert.sh's own defaults are meant to be production-ready (see its
# header comment and ../README.md). This script only overrides what's
# needed to make repeated local testing safe and fast, rather than
# changing any of lego_cert.sh's defaults:
#
#   - DEPLOY_DIR=/deploy   so testing never touches the real
#                          /run/secrets/nginx path domino-nrpc-proxy uses.
#   - LEGO_RENEW_FORCE=true so every "renew" call actually renews - a real
#                          cert that's minutes old is nowhere near lego's
#                          normal renewal window, so without forcing it
#                          "renew" would just be a silent no-op here.
#
# lego_cert.sh has two modes, selected by whether LEGO_HTTP_WEBROOT is
# set (see its README section) - this script tests standalone mode by
# default, same as lego_cert.sh's own default. Pass -webroot to test
# webroot mode instead:
#
#   ./test_lego.sh -webroot
#
# which points LEGO_HTTP_WEBROOT at TEST_HTTP_WEBROOT below - a safe,
# writable path, NOT lego_cert.sh's /local/lego/acme example, which is a
# root-level path requiring elevated privileges. Override
# TEST_HTTP_WEBROOT itself if you want webroot mode pointed elsewhere.
#
# lego_cert.sh never starts nginx itself (see lego_request_cert) - only
# reloads it. So in -webroot mode, THIS script starts a real nginx
# (start_nginx below) after init_cert has created a placeholder
# tls.crt/tls.key for it to load: one server block serves
# /.well-known/acme-challenge/ from TEST_HTTP_WEBROOT for lego's
# challenge, another terminates TLS on :443 using whatever's currently in
# DEPLOY_DIR - so lego_deploy_hook's "nginx -s reload" after each
# run/renew has something real to reload, not just a throwaway process.
# Needs a real nginx binary on $PATH. No custom "pid" directive is set,
# deliberately: leaving it at nginx's own compiled-in default means the
# bare "nginx -s reload" lego_deploy_hook calls (no -c) resolves to the
# same pidfile this script's own "nginx -c ..." start used.
#
# Usage: test_lego.sh [-webroot]
#
#   TEST_RENEW_COUNT    - number of renewals to perform before exiting (default 3)
#   TEST_RENEW_INTERVAL - seconds that must pass between renewals (default 30)
#   TEST_POLL_INTERVAL  - seconds between "is it time yet" checks (default 5)
#   TEST_HTTP_WEBROOT   - webroot path used with -webroot (default /tmp/lego-webroot)

export DEPLOY_DIR=/deploy
export LEGO_RENEW_FORCE=true

TEST_HTTP_WEBROOT="${TEST_HTTP_WEBROOT:-/tmp/lego-webroot}"

case "$1" in
  -webroot)
    export LEGO_HTTP_WEBROOT="$TEST_HTTP_WEBROOT"
    ;;
  "")
    ;;
  *)
    echo "Usage: test_lego.sh [-webroot]" >&2
    exit 1
    ;;
esac

# lego_cert.sh already creates this itself before starting its temporary
# nginx (see lego_request_cert), but doing it here too means a missing
# directory fails obviously and early rather than however nginx -c would
# report it, if something about this webroot path turns out to be wrong.
if [ -n "$LEGO_HTTP_WEBROOT" ]; then
  mkdir -p "$LEGO_HTTP_WEBROOT/.well-known/acme-challenge"
fi

TEST_RENEW_COUNT="${TEST_RENEW_COUNT:-3}"
TEST_RENEW_INTERVAL="${TEST_RENEW_INTERVAL:-30}"
TEST_POLL_INTERVAL="${TEST_POLL_INTERVAL:-5}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

header()
{
  echo
  echo "-----------------------------"
  echo "$1"
  echo "-----------------------------"
  echo
}

# Wraps lego_cert.sh's own "show" with a labeled banner, so it's obvious
# which step's certificate is being printed in a scrolling test log.
show_cert()
{
  header "$1"
  ./lego_cert.sh show
}

TEST_NGINX_CONF=/tmp/test_lego_nginx.conf

# Renders TEST_NGINX_CONF from a template (sed substitution, not a bash
# heredoc directly, so nginx's own $uri/$host variables aren't mistaken
# for shell variables) and starts nginx with it. Only called in -webroot
# mode - see the header comment for why this script (not lego_cert.sh)
# owns nginx's lifecycle.
start_nginx()
{
  echo "=== starting nginx (webroot mode demo site) ==="

  sed -e "s#__WEBROOT__#$TEST_HTTP_WEBROOT#g" -e "s#__DEPLOY_DIR__#$DEPLOY_DIR#g" > "$TEST_NGINX_CONF" <<'NGINX_CONF_EOF'
worker_processes auto;

events
{
    worker_connections 1024;
}

http
{
    default_type  application/octet-stream;

    sendfile      on;
    keepalive_timeout 65;

    server
    {
        listen 80 default_server;
        listen [::]:80 default_server;

        server_name _;

        location ^~ /.well-known/acme-challenge/
        {
            root __WEBROOT__;
            default_type text/plain;
            access_log off;
            log_not_found off;
            try_files $uri =404;
        }

        location /
        {
            return 301 https://$host$request_uri;
        }
    }

    server
    {
        listen 443 ssl;
        server_name _;

        ssl_certificate     __DEPLOY_DIR__/tls.crt;
        ssl_certificate_key __DEPLOY_DIR__/tls.key;

        location /
        {
            default_type text/plain;
            return 200 "test_lego.sh demo site OK\n";
        }
    }
}
NGINX_CONF_EOF

  nginx -c "$TEST_NGINX_CONF"
}

stop_nginx()
{
  echo "=== stopping nginx ==="
  nginx -c "$TEST_NGINX_CONF" -s quit 2>/dev/null
}

# All three functions are named/shaped to match domino-nrpc-proxy's own
# entrypoint.sh main-loop style (e.g. cert_update_check) - these are the
# units meant to be called from that loop once ported over.

init_cert()
{
  echo "=== lego_cert.sh init ==="
  ./lego_cert.sh init
  show_cert "after init"
}

run_cert()
{
  echo "=== lego_cert.sh run ==="
  ./lego_cert.sh run
  LAST_RENEW=$(date +%s)
  show_cert "after run"
}

# Tracks the last-acted timestamp in LAST_RENEW (set by run_cert) and
# compares against now; date +%s (not bash's $SECONDS) keeps this
# portable to any shell and keeps the timer state in its own variable
# rather than repurposing shell-wide state.
renew_check()
{
  NOW=$(date +%s)
  if [ $(( NOW - LAST_RENEW )) -lt "$TEST_RENEW_INTERVAL" ]; then
    return
  fi

  LAST_RENEW=$NOW
  COUNT=$((COUNT + 1))
  echo "=== lego_cert.sh renew ($COUNT/$TEST_RENEW_COUNT) ==="
  ./lego_cert.sh renew
  show_cert "after renew ($COUNT/$TEST_RENEW_COUNT)"
}

RUNNING=1
trap 'RUNNING=0' SIGTERM SIGINT

COUNT=0
init_cert

if [ -n "$LEGO_HTTP_WEBROOT" ]; then
  start_nginx
fi

run_cert

while [ "$RUNNING" = "1" ] && [ "$COUNT" -lt "$TEST_RENEW_COUNT" ]; do
  renew_check
  sleep "$TEST_POLL_INTERVAL"
done

if [ -n "$LEGO_HTTP_WEBROOT" ]; then
  stop_nginx
fi

echo "=== done ($COUNT renewals) ==="
