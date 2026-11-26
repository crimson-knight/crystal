# Changelog

## crystal-alpha (crimson-knight fork), unreleased

- `HTTP::Client` and `HTTP::WebSocket` speak TLS through Beryl only. The
  `-Duse_openssl` opt-out kept for one release in 1.22.3-incremental-3 is
  removed: `HTTP::Client::TLSClientContext` is always
  `Crystal::Beryl::TLS::Context::Client`, and a program built with
  `-Duse_openssl` gets Beryl and links no OpenSSL. TLS 1.3 only; a server
  that stops at TLS 1.2 gets an error that says so. `require "openssl"` and
  the `OpenSSL` module are unchanged for programs that use them directly.

For information on prior releases, refer to the changelogs in [./doc/changelogs](./doc/changelogs/README.md)
