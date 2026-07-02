#!/bin/bash

# Requests (or renews) a certificate via the LEGO ACME client.
# See ./install-lego.sh to fetch the lego binary itself first.

export LEGO_DOMAINS="$(hostname -f)"
export LEGO_SERVER=letsencrypt-staging
export LEGO_HTTP=true
export LEGO_KEY_TYPE=EC256
export LEGO_ACCEPT_TOS=true
export LEGO_REUSE_KEY=true
export LEGO_CERT_NAME=test
export LEGO_PEM=true
export LEGO_PATH="$(pwd)/data"

export LEGO_PRE_HOOK="$(pwd)/lego_hook.sh PRE"
export LEGO_DEPLOY_HOOK="$(pwd)/lego_hook.sh DEPLOY"
export LEGO_POST_HOOK="$(pwd)/lego_hook.sh POST"

export LEGO_LOG_LEVEL=debug
#export LEGO_EMAIL=le@example.com
#export LEGO_HTTP_WEBROOT="/local/lego/acme"

mkdir -p "$LEGO_PATH"

if [ -z "$LEGO_HTTP_WEBROOT" ]; then
  lego run
else

  mkdir -p "$LEGO_HTTP_WEBROOT/.well-known/acme-challenge"
  pkill nginx 2>/dev/null
  nginx -c "$(pwd)/nginx.conf"
  lego run
  pkill nginx 2>/dev/null

fi
