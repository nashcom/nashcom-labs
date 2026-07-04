# LEGO ACME Client Example

Demonstrates obtaining a TLS certificate directly with
[LEGO](https://github.com/go-acme/lego) - the same ACME client library
Traefik uses internally (see the [traefik](../traefik/) lab) - run here as
a standalone CLI instead of embedded in another tool.

This is a lab configuration to demonstate how LEGO works:
The first stage of adding LEGO-based certificate management as an option to the
[domino-nrpc-proxy](https://github.com/nashcom/domino-nrpc-proxy) container
image itself (which currently supports file-watch and Domino CertMgr as its
two certificate sources). The intent is to lay this script down at `/` in
the image (alongside `entrypoint.sh`, `/nginx`, etc.) and keep the LEGO
logic separate from `entrypoint.sh` rather than inlining it: `entrypoint.sh`
would call `lego_cert.sh init` once before starting nginx, `lego_cert.sh
run` once at container start, then periodically (e.g. daily) `lego_cert.sh
renew`, rather than running its own ACME protocol/hook logic in its main
loop.

## Files

```
install-lego.sh  - downloads the lego binary, verified against a pinned SHA256
lego_cert.sh     - init/run/renew a certificate, and handles lego's DEPLOY
                    hook (see below)
nginx.conf       - temporary nginx serving the ACME HTTP-01 webroot challenge
test_lego.sh     - sample script: init + run + a short forced-renew loop,
                    dumping the certificate after every step, for manual
                    end-to-end testing (see Testing below)
```

## Configuration

Every `LEGO_*` variable `lego_cert.sh` sets is overridable from the
environment - it only falls back to the value below when unset:

| Variable            | Default                | Notes                                    |
|----------------------|-------------------------|-------------------------------------------|
| `LEGO_DOMAINS`       | `$(hostname -f)`        |                                            |
| `LEGO_SERVER`        | `letsencrypt-staging`   | Untrusted certs, higher rate limits       |
| `LEGO_HTTP`          | `true`                  | lego's built-in standalone HTTP-01 solver |
| `LEGO_KEY_TYPE`      | `EC256`                 |                                            |
| `LEGO_ACCEPT_TOS`    | `true`                  |                                            |
| `LEGO_REUSE_KEY`     | `false`                 | Rotate the private key on every renewal (lego's own default) |
| `LEGO_CERT_NAME`     | `nginx`                 | Filename prefix under `$LEGO_PATH/certificates/` |
| `LEGO_PEM`           | `true`                  |                                            |
| `LEGO_PATH`          | `$(pwd)/data`           | ACME account key + issued certificates    |
| `LEGO_LOG_LEVEL`     | `info`                  | `DEBUG`/`INFO`/`WARN`/`ERROR` - avoid `debug` as a standing default (verbose, not meant for routine production logs) |
| `LEGO_EMAIL`         | empty                   | e.g. `le@example.com` - not exported to lego when empty (see below) |
| `LEGO_HTTP_WEBROOT`  | empty                   | e.g. `/local/lego/acme` - set to switch to webroot mode; not exported to lego when empty (see below) |

`NGINX_UID`/`NGINX_GID` and `DEPLOY_DIR` (used by `init_tls_cert` and the
`DEPLOY` hook, not passed to lego) default to `1000`/`1000` and
`/run/secrets/nginx` respectively, and are overridable the same way.

`LEGO_BIN` (default `/lego`) is the path to the lego binary itself -
matches the real container image, which places it at `/lego` rather than
installing it on `$PATH` (see `install-lego.sh`). `lego_request_cert`
calls it by this absolute path rather than a bare `lego` command,
specifically so it can never be shadowed by a shell function of the same
name - see the comment on `lego_acme()` for why that matters.

`LEGO_DEPLOY_HOOK` is the one exception - it's always set to
`"$0 hook DEPLOY"` and isn't meant to be overridden, since that's what
wires the certificate deployment back into this script.

`LEGO_EMAIL` and `LEGO_HTTP_WEBROOT` are only `export`ed when non-empty,
unlike every other variable above. lego reads its flags from the
environment via Go's `os.LookupEnv`, which distinguishes "unset" from
"set to an empty string" - `export`ing them unconditionally (even as `""`)
made lego see the flag as explicitly provided with an empty value rather
than not provided at all. In practice this broke standalone mode: an
empty, but present, `LEGO_HTTP_WEBROOT` made lego try to build a webroot
challenge provider with an empty path, failing with `webroot provider ()
webroot path does not exist`. `lego_configure` now assigns the value
locally either way (so `lego_request_cert`'s own `[ -z "$LEGO_HTTP_WEBROOT" ]`
check still works), but only `export`s it - or explicitly `export -n`s it
if a caller had already exported an empty one - when it's actually
non-empty.

## How it works

`lego_cert.sh` takes an action as its one argument:

```bash
lego_cert.sh init    # ensure tls.crt/tls.key exist - self-signed placeholder
                      # via openssl if missing, so nginx can start immediately
lego_cert.sh run     # obtain a new certificate - call once at container start
lego_cert.sh renew   # renew an existing one - call periodically (e.g. daily);
                      # a no-op if it isn't due for renewal yet
lego_cert.sh show    # print a short summary (SAN, subject, issuer,
                      # expiration, fingerprint, serial) of the certificate
                      # currently in DEPLOY_DIR - troubleshooting/testing
                      # only, not part of the normal init/run/renew flow
```

`init` solves a bootstrap problem: nginx won't start at all if its
configured `ssl_certificate`/`ssl_certificate_key` files don't exist yet,
but on first start there's no real certificate until lego successfully
completes an ACME order - which nginx itself may need to be up for (to
answer the HTTP-01 challenge, or just to serve anything at all in the
meantime). `init_tls_cert` checks `$DEPLOY_DIR/tls.crt` and `tls.key`; if
both are already there it does nothing, otherwise it generates a
self-signed EC256 placeholder with `openssl req -x509 -noenc` (30 days,
CN/SAN set to `LEGO_DOMAINS`) so nginx has something to load. `lego_deploy_hook`
(below) overwrites it with the real certificate as soon as one is issued.
Being self-signed, it's untrusted by any client regardless of CN/SAN
correctness - it only needs to exist, not to be trusted.

`lego_cert.sh` supports two ways of completing the ACME HTTP-01 challenge,
selected by whether `LEGO_HTTP_WEBROOT` is set:

- **Standalone (default)** - `LEGO_HTTP=true` and `LEGO_HTTP_WEBROOT` unset:
  lego binds its own embedded HTTP listener to answer the challenge itself.
  No nginx involved.
- **Webroot** - set `LEGO_HTTP_WEBROOT` (e.g.
  `LEGO_HTTP_WEBROOT=/local/lego/acme ./lego_cert.sh run`): `lego_cert.sh`
  instead starts the bundled `nginx.conf` (which serves
  `/local/lego/acme/.well-known/acme-challenge/`), runs lego, then stops
  that nginx again. Use this when port 80 needs to keep serving other
  content and only the challenge path should be handed to lego.

Either way, lego calls back into `lego_cert.sh` after a certificate has
been issued or renewed, via `LEGO_DEPLOY_HOOK`, set to
`"$0 hook DEPLOY"`. lego execs whatever command string is in that
variable as a separate subprocess - it can't call a function in the
already-running script directly - so `lego_cert.sh hook DEPLOY` is how it
re-enters itself and dispatches to the `lego_deploy_hook` function. The exported
`LEGO_*` variables are still inherited by that child process. (lego also
supports PRE and POST hooks; unused here since there's nothing to do at
those stages.)

`lego_deploy_hook` copies the PEM cert/key from `$LEGO_PATH/certificates/` to
`$DEPLOY_DIR/tls.crt` and `tls.key`. `DEPLOY_DIR` defaults to
`/run/secrets/nginx` - `domino-nrpc-proxy`'s own mount point for TLS
material (`NGINX_SSL_CERT`/`NGINX_SSL_KEY` in its `entrypoint.md`), the
same path [traefik/get_cert_for_nginx.sh](../traefik/get_cert_for_nginx.sh)
writes to. If run as root, it `chown`s both to UID/GID 1000 (override with
`NGINX_UID`/`NGINX_GID`) - `domino-nrpc-proxy`'s own convention for its
non-root `nginx` account, not the UID 101 used by the official
`nginx:latest` image (see the same script for the same pattern). If not
root, it falls back to making `tls.key` world-readable instead, with a
warning. Finally it runs `nginx -s reload` if nginx is running.

## Known rough edge

`nginx.conf`'s challenge webroot is hardcoded to `/local/lego/acme`
(matching this environment's `/local` convention). If you set
`LEGO_HTTP_WEBROOT` to switch to webroot mode, it needs to be set to that
same path (or `nginx.conf` edited to match) - they're not linked
automatically. Since `LEGO_HTTP_WEBROOT` is empty by default, the
standalone mode (which doesn't use `nginx.conf` at all) is what actually
runs out of the box.

## Usage

```bash
./install-lego.sh      # fetch the lego binary to /lego (once)
./lego_cert.sh run      # obtain a new certificate
./lego_cert.sh renew    # renew it, e.g. from a daily cron job
```

`install-lego.sh` writes to `/lego` by default (override with
`LEGO_INSTALL_PATH`), which needs root/write access to `/` just like
installing to `/usr/local/bin` would - no new requirement, just a
different target path matching the real container image.

Defaults to Let's Encrypt **staging** (`LEGO_SERVER=letsencrypt-staging`,
untrusted certs, higher rate limits) - switch to production only once the
flow is confirmed working. Requires port 80 to be reachable from the
internet for the HTTP-01 challenge, same as the [traefik](../traefik/) lab.

`$LEGO_PATH` (`data/`) holds the ACME account key and all issued
certificate private keys - excluded from git via `.gitignore`.

## Testing

`lego_cert.sh`'s defaults are meant to be production-ready as-is (that's
the point of the [Configuration](#configuration) table above) - testing
overrides what it needs on top, rather than changing any of
`lego_cert.sh`'s own defaults:

```bash
./test_lego.sh
```

This calls `init_cert` (`lego_cert.sh init`, then `show_cert "after
init"`), then `run_cert` (`lego_cert.sh run`, seeds `LAST_RENEW`, then
`show_cert "after run"`), then polls in a `while` loop (`TEST_POLL_INTERVAL`
seconds between checks, default 5) calling `renew_check` each tick, which
calls `lego_cert.sh renew` (and `show_cert` again, labeled with the
renewal count) once `TEST_RENEW_INTERVAL` seconds (default 30) have
passed, up to `TEST_RENEW_COUNT` times (default 3). `show_cert` wraps
`lego_cert.sh show` with a `header` banner (a labeled `----` block) so
each step's certificate is easy to pick out in a scrolling test log -
placeholder after `init`, then the real one after `run`, then each
renewal's. All these functions are named and shaped to match
`domino-nrpc-proxy`'s own `entrypoint.sh` main-loop style (which calls
named functions like `cert_update_check` each iteration) - they're the
units meant to be called from that loop once ported over. `renew_check`
tracks the last-acted timestamp (`date +%s`) in its own variable and
compares against now - deliberately not bash's `$SECONDS`, since that's
shell-wide state something else might expect to reflect true elapsed
time, and `date` keeps the pattern portable to any shell. Two overrides
make repeated local testing safe and meaningful:

- `DEPLOY_DIR=/deploy` - so testing never writes into the real
  `/run/secrets/nginx` path.
- `LEGO_RENEW_FORCE=true` - lego only renews a certificate close to its
  real expiry; a cert that's seconds or minutes old is nowhere near that
  window, so without forcing it, every `renew` call in the loop would
  silently no-op instead of actually exercising the renewal + `DEPLOY`
  hook path.

`test_lego.sh` doesn't set `LEGO_HTTP_WEBROOT` itself, so it tests
standalone mode by default (same as `lego_cert.sh`'s own default). To
test webroot mode instead, set it yourself to a safe, writable path when
invoking the script - not `lego_cert.sh`'s `/local/lego/acme` example,
which is a root-level path requiring elevated privileges:

```bash
LEGO_HTTP_WEBROOT=/tmp/lego-webroot ./test_lego.sh
```

`test_lego.sh` pre-creates `$LEGO_HTTP_WEBROOT/.well-known/acme-challenge`
when set, in addition to `lego_cert.sh`'s own internal creation - so a
bad path fails obviously and early rather than however `nginx -c` would
happen to report it.
