# LEGO ACME Client Example

Demonstrates obtaining a TLS certificate directly with
[LEGO](https://github.com/go-acme/lego) - the same ACME client library
Traefik uses internally (see the [traefik](../traefik/) lab) - run here as
a standalone CLI instead of embedded in another tool.

This is a lab configuration to demonstate how LEGO works:
The first stage of adding LEGO-based certificate management as an option to the
[domino-nrpc-proxy](https://github.com/nashcom/domino-nrpc-proxy) container
image itself (which currently supports file-watch and Domino CertMgr as its
two certificate sources). The scripts here are written to be portable into
that image's `entrypoint.sh` largely as-is.

## Files

```
install-lego.sh  - downloads the lego binary, verified against a pinned SHA256
run.sh           - sets LEGO_* config and requests/renews the certificate
lego_hook.sh     - PRE/DEPLOY/POST hook invoked by lego during run.sh
nginx.conf       - temporary nginx serving the ACME HTTP-01 webroot challenge
```

## How it works

`run.sh` supports two ways of completing the ACME HTTP-01 challenge,
selected by whether `LEGO_HTTP_WEBROOT` is set:

- **Standalone (default)** - `LEGO_HTTP=true` and `LEGO_HTTP_WEBROOT` unset:
  lego binds its own embedded HTTP listener to answer the challenge itself.
  No nginx involved.
- **Webroot** - uncomment `LEGO_HTTP_WEBROOT` in `run.sh`: `run.sh` instead
  starts the bundled `nginx.conf` (which serves
  `/local/lego/acme/.well-known/acme-challenge/`), runs `lego run`, then
  stops that nginx again. Use this when port 80 needs to keep serving other
  content and only the challenge path should be handed to lego.

Either way, lego calls `lego_hook.sh` at three points (via
`LEGO_PRE_HOOK`/`LEGO_DEPLOY_HOOK`/`LEGO_POST_HOOK`):

- `PRE` - before the order/validation starts.
- `DEPLOY` - after a certificate has been issued or renewed. Copies the PEM
  cert/key from `$LEGO_PATH/certificates/` to `deployed/tls.crt` and
  `tls.key`. If run as root, `chown`s both to UID/GID 1000 (override with
  `NGINX_UID`/`NGINX_GID`) - `domino-nrpc-proxy`'s own convention for its
  non-root `nginx` account, not the UID 101 used by the official
  `nginx:latest` image (see [traefik/get_cert_for_nginx.sh](../traefik/get_cert_for_nginx.sh)
  for the same pattern). If not root, falls back to making `tls.key`
  world-readable instead, with a warning. Finally runs `nginx -s reload` if
  nginx is running.
- `POST` - after the run completes.

## Known rough edge

`nginx.conf`'s challenge webroot is hardcoded to `/local/lego/acme`
(matching this environment's `/local` convention), while
`LEGO_HTTP_WEBROOT` in `run.sh` is commented out by default - uncomment it
with the same path if you switch to webroot mode. Since it's unset by
default, the standalone mode (which doesn't use `nginx.conf` at all) is
what actually runs out of the box.

## Usage

```bash
./install-lego.sh   # fetch the lego binary (once)
./run.sh             # request/renew the certificate
```

Defaults to Let's Encrypt **staging** (`LEGO_SERVER=letsencrypt-staging`,
untrusted certs, higher rate limits) - switch to production only once the
flow is confirmed working. Requires port 80 to be reachable from the
internet for the HTTP-01 challenge, same as the [traefik](../traefik/) lab.

`$LEGO_PATH` (`data/`) holds the ACME account key and all issued
certificate private keys - excluded from git via `.gitignore`, same as
`deployed/`.
