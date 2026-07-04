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
# Usage: test_lego.sh
#
#   TEST_RENEW_COUNT    - number of renewals to perform before exiting (default 3)
#   TEST_RENEW_INTERVAL - seconds that must pass between renewals (default 30)
#   TEST_POLL_INTERVAL  - seconds between "is it time yet" checks (default 5)

export DEPLOY_DIR=/deploy
export LEGO_RENEW_FORCE=true

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
run_cert

while [ "$RUNNING" = "1" ] && [ "$COUNT" -lt "$TEST_RENEW_COUNT" ]; do
  renew_check
  sleep "$TEST_POLL_INTERVAL"
done

echo "=== done ($COUNT renewals) ==="
