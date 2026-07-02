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
# Usage: ./get_cert_for_nginx.sh [cert]
#
#   cert - additionally dump the extracted certificate as text

ACME_JSON=data/acme.json
CERT_FILE=secrets/tls.crt
KEY_FILE=secrets/tls.key

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

echo "Extracted certificate for [$MATCH_DOMAIN]"

if [ "$1" = "cert" ]; then
  openssl x509 -noout -text -in "$CERT_FILE"
fi
