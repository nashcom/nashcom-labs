#!/bin/bash

# Demo script: shows how to hand a Traefik-issued ACME certificate to a
# service that terminates TLS itself, by pulling it out of acme.json.
# Not intended as production automation (no cron, no CertMgr integration).
#
# acme.json is written by LEGO, the ACME client library Traefik uses
# internally. Under the resolver name (here: "le") it stores the ACME
# account plus a Certificates[] array, one entry per issued certificate:
#   { "domain": { "main": "...", "sans": [...] },
#     "certificate": "<base64 PEM cert chain>",
#     "key":         "<base64 PEM private key>" }
# The certificate entry is matched by domain name (main or SAN), then its
# certificate/key fields are base64-decoded to PEM files.
#
# domino-nrpc-proxy's entrypoint watches /run/secrets/nginx for file changes
# and reloads nginx itself (within INTERVAL_SECONDS, default 10s), so this
# script does not need to trigger a reload.
#
# The nginx container runs as a fixed non-root account, UID/GID 1000
# ("nginx", created via useradd nginx -U in the image) - this is
# domino-nrpc-proxy's own convention, NOT the UID 101 used by the official
# nginx:latest image, so don't assume the usual value. When this script
# runs as root, it chowns the extracted files to that UID/GID so the
# container can read tls.key despite its restrictive mode. When run as a
# regular user, chown to another UID isn't possible, so the key is instead
# made group/world-readable - only do this on a host where that's
# acceptable, since it exposes the private key more broadly.
#
# Usage: ./get_cert_for_nginx.sh [cert]
#
#   cert - additionally dump the extracted certificate as text

ACME_JSON=data/acme.json
CERT_FILE=secrets/tls.crt
KEY_FILE=secrets/tls.key

NGINX_UID=${NGINX_UID:-1000}
NGINX_GID=${NGINX_GID:-1000}

# Get DOMAIN from .env if present
if [ -f .env ]; then
  . ./.env
fi

MATCH_DOMAIN=${MATCH_DOMAIN:-${DOMAIN:-example.com}}

if [ ! -r "$ACME_JSON" ]; then
  echo "Cannot read $ACME_JSON - did Traefik obtain a certificate yet?"
  exit 1
fi

JQ_SELECT='.le.Certificates[]? | select((.domain.main == $d) or ((.domain.sans // []) | index($d)))'

CERT=$(jq -r --arg d "$MATCH_DOMAIN" "$JQ_SELECT | .certificate" "$ACME_JSON")
KEY=$(jq -r --arg d "$MATCH_DOMAIN" "$JQ_SELECT | .key" "$ACME_JSON")

if [ -z "$CERT" ] || [ "$CERT" = "null" ] || [ -z "$KEY" ] || [ "$KEY" = "null" ]; then
  echo "No certificate found for [$MATCH_DOMAIN] in $ACME_JSON"
  exit 1
fi

echo "$CERT" | base64 -d > "$CERT_FILE"
echo "$KEY"  | base64 -d > "$KEY_FILE"

chmod 644 "$CERT_FILE"
chmod 600 "$KEY_FILE"

if [ "$(id -u)" = "0" ]; then
  chown "$NGINX_UID:$NGINX_GID" "$CERT_FILE" "$KEY_FILE"
else
  echo "Not running as root - cannot chown to $NGINX_UID:$NGINX_GID."
  echo "Making $KEY_FILE group/world-readable so UID $NGINX_UID can read it."
  chmod 644 "$KEY_FILE"
fi

echo "Extracted certificate for [$MATCH_DOMAIN]"

if [ "$1" = "cert" ]; then
  openssl x509 -noout -text -in "$CERT_FILE"
fi
