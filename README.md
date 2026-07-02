# nashcom-labs

Nash!Com Labs - small demo/reference environments for infrastructure patterns.

## Labs

- [traefik](traefik/) - Traefik reverse proxy with automatic ACME certificates,
  paired with a [domino-nrpc-proxy](https://github.com/nashcom/domino-nrpc-proxy)
  service that reuses the issued certificate to terminate TLS itself. Includes
  a `whoami` echo backend reachable four different ways (via Traefik, via
  nginx, and directly bypassing each), useful for seeing how host- vs.
  path-based routing and TLS termination interact - see the
  [lab's README](traefik/README.md#accessing-whoami) for details and curl
  examples.
- [lego](lego/) - Obtains a certificate directly with the
  [LEGO](https://github.com/go-acme/lego) ACME client (the library Traefik
  uses internally) instead of going through Traefik. A prototype for adding
  LEGO-based certificate management to the `domino-nrpc-proxy` image itself.
