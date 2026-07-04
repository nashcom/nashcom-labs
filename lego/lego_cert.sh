#!/bin/bash

# Requests or renews a certificate via the LEGO ACME client.
# See ./install-lego.sh to fetch the lego binary itself first.
#
# Everything here is a function so this can be copied into another
# script (e.g. domino-nrpc-proxy's entrypoint.sh) largely as-is - only
# lego_acme() at the bottom is standalone-CLI-specific.
#
# Usage: lego_cert.sh <init|run|renew|show>
#
#   init   - ensure tls.crt/tls.key exist in DEPLOY_DIR, generating a
#            self-signed placeholder with openssl if missing, so nginx
#            has something to start with even before a real certificate
#            has been issued. Call this once at container start, before
#            starting nginx and before "run".
#   run    - obtain a new certificate. Call this once at container start.
#   renew  - renew an existing certificate if it's due; a no-op otherwise.
#            Call this periodically (e.g. daily) once the container is up.
#   show   - print a short summary (SAN, subject, issuer, expiration,
#            fingerprint, serial) of the certificate currently in
#            DEPLOY_DIR - for troubleshooting/testing, not called as
#            part of the normal init/run/renew flow.
#
# lego (v5) has no separate "renew" subcommand - "lego run" is the only
# one, and it decides internally whether to obtain or renew based on
# whether a certificate resource already exists in LEGO_PATH. Our own
# run/renew actions are therefore both wired to the same "lego run"
# invocation (see lego_request_cert) - they only differ in when
# entrypoint.sh is meant to call them, not in what lego itself is told to
# do. LEGO_RENEW_FORCE etc. are still valid, since they're flags of the
# "run" command itself, not of a separate "renew" one.
#
# lego calls the DEPLOY hook as a separate subprocess (it just execs
# whatever command string is in LEGO_DEPLOY_HOOK), so it can't call a bash
# function in this same process directly. Instead this script re-invokes
# itself via $0 as "$0 hook DEPLOY", dispatching to lego_deploy_hook below - the
# export'd LEGO_* variables are still inherited by that child process.
# $0 works here even when relative, since neither this script nor lego
# ever changes directory between the initial invocation and lego execing
# the hook. PRE/POST aren't used - there's nothing to do at those stages.

# All LEGO_* variables set here are overridable from the environment -
# each only falls back to this lab's default when unset. Always run
# first, regardless of action, since init_tls_cert/lego_deploy_hook also depend
# on NGINX_UID/NGINX_GID/LEGO_PATH/LEGO_DOMAINS being set.

lego_configure()
{
  # domino-nrpc-proxy's own convention, not the UID 101 used by the
  # official nginx:latest image - see ../traefik/get_cert_for_nginx.sh.
  NGINX_UID=${NGINX_UID:-1000}
  NGINX_GID=${NGINX_GID:-1000}

  # The real container image deploys the lego binary at /lego, not on
  # $PATH - see install-lego.sh. Called by absolute path (not bare "lego")
  # so it can never be shadowed by a shell function of the same name,
  # regardless of what this script or anything sourcing it happens to
  # define - see the note on lego_acme() below for why that already bit us.
  LEGO_BIN="${LEGO_BIN:-/lego}"

  export LEGO_DOMAINS="${LEGO_DOMAINS:-$(hostname -f)}"
  export LEGO_SERVER="${LEGO_SERVER:-letsencrypt-staging}"
  export LEGO_HTTP="${LEGO_HTTP:-true}"
  export LEGO_KEY_TYPE="${LEGO_KEY_TYPE:-EC256}"
  export LEGO_ACCEPT_TOS="${LEGO_ACCEPT_TOS:-true}"
  export LEGO_REUSE_KEY="${LEGO_REUSE_KEY:-false}"
  export LEGO_CERT_NAME="${LEGO_CERT_NAME:-nginx}"
  export LEGO_PEM="${LEGO_PEM:-true}"
  export LEGO_PATH="${LEGO_PATH:-$(pwd)/data}"
  export LEGO_LOG_LEVEL="${LEGO_LOG_LEVEL:-info}"

  # Empty by default - set from the environment to opt in. Deliberately
  # NOT exported when empty: lego reads these via os.LookupEnv, which
  # distinguishes "unset" from "set to empty string" - export="" would
  # make lego see the flag as explicitly provided (empty value) rather
  # than absent, e.g. LEGO_HTTP_WEBROOT="" made lego try to build a
  # webroot challenge provider with an empty path ("webroot provider ()").
  LEGO_EMAIL="${LEGO_EMAIL:-}"                # e.g. le@example.com
  LEGO_HTTP_WEBROOT="${LEGO_HTTP_WEBROOT:-}"  # e.g. /local/lego/acme - switches to webroot mode when set
  if [ -n "$LEGO_EMAIL" ]; then export LEGO_EMAIL; else export -n LEGO_EMAIL 2>/dev/null; fi
  if [ -n "$LEGO_HTTP_WEBROOT" ]; then export LEGO_HTTP_WEBROOT; else export -n LEGO_HTTP_WEBROOT 2>/dev/null; fi

  # Not overridable - wires lego's DEPLOY hook back into this same script.
  export LEGO_DEPLOY_HOOK="$0 hook DEPLOY"
}

# Shared by lego_deploy_hook and init_tls_cert: fix up a freshly written cert/key
# pair so the nginx container can actually read it.

secure_tls_deploy()
{
  local cert="$1"
  local key="$2"

  chmod 644 "$cert"
  chmod 600 "$key"

  if [ "$(id -u)" = "0" ]; then
    chown "$NGINX_UID:$NGINX_GID" "$cert" "$key"
  else
    echo "[lego_cert] not running as root - cannot chown to $NGINX_UID:$NGINX_GID."
    echo "[lego_cert] making $(basename "$key") group/world-readable so UID $NGINX_UID can read it."
    chmod 644 "$key"
  fi
}

lego_deploy_hook()
{
  echo "[lego_cert] DEPLOY: certificate issued, deploying"

  # /run/secrets/nginx is domino-nrpc-proxy's own convention - the mount
  # point its entrypoint watches for tls.crt/tls.key (see NGINX_SSL_CERT/
  # NGINX_SSL_KEY in its entrypoint.md), same path traefik/get_cert_for_nginx.sh
  # writes to. Override to something else (e.g. for local testing) via
  # DEPLOY_DIR in the environment.
  local DEPLOY_DIR="${DEPLOY_DIR:-/run/secrets/nginx}"
  local CERT_NAME="${LEGO_CERT_NAME:-nginx}"

  mkdir -p "$DEPLOY_DIR"

  cp "$LEGO_PATH/certificates/${CERT_NAME}.crt" "$DEPLOY_DIR/tls.crt"
  cp "$LEGO_PATH/certificates/${CERT_NAME}.key" "$DEPLOY_DIR/tls.key"

  secure_tls_deploy "$DEPLOY_DIR/tls.crt" "$DEPLOY_DIR/tls.key"

  # Reload the nginx serving this certificate to pick up the new files.
  if pgrep -x nginx > /dev/null 2>&1; then
    nginx -s reload
    echo "[lego_cert] DEPLOY: nginx reloaded"
  else
    echo "[lego_cert] DEPLOY: nginx not running, skipped reload"
  fi
}

init_tls_cert()
{
  local DEPLOY_DIR="${DEPLOY_DIR:-/run/secrets/nginx}"

  if [ -f "$DEPLOY_DIR/tls.crt" ] && [ -f "$DEPLOY_DIR/tls.key" ]; then
    echo "[lego_cert] INIT: tls.crt/tls.key already present in $DEPLOY_DIR, nothing to do"
    return
  fi

  local domain="${LEGO_DOMAINS:-$(hostname -f)}"

  echo "[lego_cert] INIT: no certificate in $DEPLOY_DIR - creating a self-signed placeholder for $domain so nginx can start"

  mkdir -p "$DEPLOY_DIR"

  # OpenSSL 3 syntax: -noenc (replaces the older -nodes) and -addext for
  # the SAN modern clients expect alongside the CN. This cert is only a
  # placeholder - untrusted regardless of CN/SAN - meant to be overwritten
  # by lego_deploy_hook as soon as a real certificate has been issued.

  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -noenc \
    -keyout "$DEPLOY_DIR/tls.key" \
    -out "$DEPLOY_DIR/tls.crt" \
    -days 30 \
    -subj "/CN=$domain" \
    -addext "subjectAltName=DNS:$domain"

  secure_tls_deploy "$DEPLOY_DIR/tls.crt" "$DEPLOY_DIR/tls.key"
}

show_cert()
{
  if [ -z "$1" ]; then
    return 0
  fi

  if [ ! -e "$1" ]; then
    return 0
  fi

  local SAN=$(openssl x509 -in "$1" -noout -ext subjectAltName | grep -E 'DNS:|IP Address:' | xargs )
  local SUBJECT=$(openssl x509 -in "$1" -noout -subject | cut -d '=' -f 2- )
  local ISSUER=$(openssl x509 -in "$1" -noout -issuer | cut -d '=' -f 2- )
  local EXPIRATION=$(openssl x509 -in "$1" -noout -enddate | cut -d '=' -f 2- )
  local FINGERPRINT=$(openssl x509 -in "$1" -noout -fingerprint | cut -d '=' -f 2- )
  local SERIAL=$(openssl x509 -in "$1" -noout -serial | cut -d '=' -f 2- )

  echo
  echo "SAN         : $SAN"
  echo "Subject     : $SUBJECT"
  echo "Issuer      : $ISSUER"
  echo "Expiration  : $EXPIRATION"
  echo "Fingerprint : $FINGERPRINT"
  echo "Serial      : $SERIAL"
  echo "File        : $1"
  echo
}

# Shared by the "run" and "renew" actions - both invoke "lego run" (see
# the note above), lego itself decides obtain vs renew.
#
# lego_cert.sh never starts, stops, or restarts nginx - only reloads it
# (see lego_deploy_hook). In webroot mode, nginx is assumed to already be
# running and already serving /.well-known/acme-challenge/ from
# LEGO_HTTP_WEBROOT - that's whoever's job it is to start nginx in the
# first place (entrypoint.sh in the real image, test_lego.sh for this
# demo), not lego_cert.sh's.

lego_request_cert()
{
  mkdir -p "$LEGO_PATH"

  if [ -n "$LEGO_HTTP_WEBROOT" ]; then
    mkdir -p "$LEGO_HTTP_WEBROOT/.well-known/acme-challenge"
  fi

  "$LEGO_BIN" run
}

# Standalone-CLI-specific: argument parsing and dispatch. Not needed if
# the functions above are copied into a script that calls them directly.
# Named lego_acme rather than plain "lego": lego_request_cert calls the
# real lego binary by absolute path ($LEGO_BIN, see lego_configure), so a
# function literally named "lego" wouldn't collide with that call site -
# but naming this one lego_acme anyway means no future bare "lego" call
# added elsewhere in this file could silently reintroduce the infinite
# recursion this exact mistake caused twice already.

lego_acme()
{
  lego_configure

  if [ "$1" = "hook" ]; then
    case "$2" in
      DEPLOY) lego_deploy_hook ;;
      *)      echo "[lego_cert] Unknown hook stage: $2" >&2; exit 1 ;;
    esac
    exit $?
  fi

  local action="${1:?Usage: lego_cert.sh <init|run|renew|show>}"

  case "$action" in
    init)  init_tls_cert ;;
    run)   lego_request_cert ;;
    renew) lego_request_cert ;;
    show)  show_cert "${DEPLOY_DIR:-/run/secrets/nginx}/tls.crt" ;;
    *)     echo "Unknown action: $action (expected init, run, renew, or show)" >&2; exit 1 ;;
  esac
}

lego_acme "$@"
