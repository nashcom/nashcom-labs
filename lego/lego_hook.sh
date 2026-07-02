#!/bin/bash

# Hook script invoked by lego via LEGO_PRE_HOOK / LEGO_DEPLOY_HOOK /
# LEGO_POST_HOOK (see run.sh) at each stage of certificate issuance
# or renewal.
#
# Usage: lego_hook.sh <PRE|DEPLOY|POST>

STAGE="$1"

LEGO_PATH="${LEGO_PATH:-$(pwd)/data}"
LEGO_CERT_NAME="${LEGO_CERT_NAME:-test}"

DEPLOY_DIR="$(pwd)/deployed"

case "$STAGE" in

  PRE)
    echo "[lego_hook] PRE: requesting/renewing certificate for $LEGO_DOMAINS"
    ;;

  DEPLOY)
    echo "[lego_hook] DEPLOY: certificate issued, deploying"

    mkdir -p "$DEPLOY_DIR"

    cp "$LEGO_PATH/certificates/${LEGO_CERT_NAME}.crt" "$DEPLOY_DIR/tls.crt"
    cp "$LEGO_PATH/certificates/${LEGO_CERT_NAME}.key" "$DEPLOY_DIR/tls.key"
    chmod 600 "$DEPLOY_DIR/tls.key"

    # Reload the nginx serving this certificate to pick up the new files.
    if pgrep -x nginx > /dev/null 2>&1; then
      nginx -s reload
      echo "[lego_hook] DEPLOY: nginx reloaded"
    else
      echo "[lego_hook] DEPLOY: nginx not running, skipped reload"
    fi
    ;;

  POST)
    echo "[lego_hook] POST: done"
    ;;

  *)
    echo "[lego_hook] Unknown stage: $STAGE" >&2
    exit 1
    ;;

esac
