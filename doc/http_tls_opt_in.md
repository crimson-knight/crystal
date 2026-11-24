# TLS in `HTTP::Server` is opt-in

`require "http/server"` links no OpenSSL. A server that never asks for TLS
has no `libssl` or `libcrypto` in `otool -L` (or `ldd`) and imports no
`SSL_`, `BIO_`, `ERR_` or `X509_` symbol:

```console
$ crystal build server.cr          # require "http/server" only
$ otool -L server                  # no libssl, no libcrypto
$ nm -u server | grep -cE '_(SSL|BIO|ERR|X509)_'
0
```

## How a program gets TLS

`HTTP::Server#bind_tls` and the `tls://` scheme of `HTTP::Server#bind` live
in `src/http/server/tls.cr`. A program gets them by requiring any of:

| Require | Gets the TLS listener |
|---|---|
| `http/server` | no |
| `http/server/tls` | yes |
| `openssl`, before or after `http/server` | yes |
| `http/client`, `http/web_socket` or `http` (each requires `openssl`) | yes |

Both orders work: `http/server.cr` ends by requiring `./server/tls` when
`OpenSSL::SSL::Server` is already defined, and `openssl.cr` ends by requiring
`./http/server/tls` when `HTTP::Server#bind_tcp` is already defined. Inside
`HTTP::Server`, the TLS handshake in `handle_client` and the `tls://` branch
of `bind` are guarded by `{% if HTTP::Server.has_method?(:bind_tls) %}` in
the method body, which the compiler expands after every file is required.

## What still requires OpenSSL

- `HTTP::Client` requires `openssl`, so `HTTP::Client.get("https://...")`
  works with `require "http/client"` alone, as before.
- `HTTP::WebSocket` is split in two. `http/web_socket/core.cr` holds the
  socket and protocol that a server needs, and `HTTP::WebSocketHandler`
  requires only that, so a server that accepts WebSockets links no OpenSSL.
  `http/web_socket/client.cr` holds the four constructors that open a
  connection (`HTTP::WebSocket.new(uri)`, `.new(host, path, port, tls)` and
  the two `Protocol.new` overloads); it requires `http/client`.
  `require "http/web_socket"` requires both, as before.
- `Digest::SHA1`, `Digest::SHA256`, `Digest::SHA512`, `Digest::MD5`,
  `OpenSSL::HMAC`, `OpenSSL::Cipher` and `OAuth` still use OpenSSL.

## Compatibility for plain Crystal programs

| Program | Before | Now |
|---|---|---|
| `require "http"` and anything it defines | works | works, unchanged |
| `require "http/client"` with `https://` | works | works, unchanged |
| `require "http/web_socket"`, `wss://` | works | works, unchanged |
| `require "http/server"`, plain HTTP | links OpenSSL | links no OpenSSL |
| `require "http/server"` and `bind_tls` or `bind("tls://...")`, nothing else requiring `openssl` | works | `bind_tls`: compile error `undefined method 'bind_tls'` (and `OpenSSL` undefined for the context); `bind("tls://...")`: raises `ArgumentError` at run time, naming `require "http/server/tls"`. Fix: add `require "http/server/tls"` (or `require "openssl"`) |
| A program that names `OpenSSL::...` after `require "http/server"` only | works | `undefined constant OpenSSL`. Fix: `require "openssl"` |
| `require "http/server"` and `HTTP::WebSocket.new(uri)` (client side) without `require "http/web_socket"` | works | `undefined method`. Fix: `require "http/web_socket"` |
| `require "http/web_socket/protocol"` alone, then `Protocol.new(host, path, ...)` | works | require `http/web_socket` |
| `require "mime/media_type"` and `HTTP::...` without requiring `http` | works: `mime/media_type.cr` required all of `http` though it uses none of it | `undefined constant HTTP`. Fix: require the `http` part the program uses. `mime/multipart` now requires the HTTP types it takes (`http/headers`, `http/request`, `http/client/response`) itself |
| `-Dwithout_openssl` | no TLS | no TLS, unchanged |

Shards that support stock Crystal and want a server without OpenSSL can
require `http/server` (instead of `http`) and
`http/server/handlers/websocket_handler` (instead of `http/web_socket`):
both paths exist in every Crystal release, and on this fork they bring in
no OpenSSL.

## Later

Beryl, the pure-Crystal cryptography library, could back TLS here once its
TLS layer is ready; that would let `http/client` and `http/server/tls` link
no OpenSSL either. Out of scope for this change.
