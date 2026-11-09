# Web demo

A page that runs minipg in the browser. It opens a busybox shell with
`minipg` on PATH, and Postgres 18 for 386 Linux runs on h9's browser host
(v86 in a Web Worker). It uses the Linux build (`-Dhost=linux`), where
Postgres serves on its unix socket alone, because the page has no TCP.

```sh
make root ARCH=386     # assets/root-386.tar.xz
make web NODE=node24   # .zig-out/web
cd .zig-out/web && python3 -m http.server
```

Any static server works. The page needs JavaScript Promise Integration
(Chrome 137 or later). It downloads about 24 MB of root (minipg.h9a.gz)
plus h9.wasm.

- `build.sh` makes it all: h9's browser host from deps/hyper9 (or `H9`),
  minipg for x86-linux-musl, a template cluster made by running
  `minipg init` under h9-node, a trimmed root, and xterm.js from npm.
- `trim.sh` cuts the postgres:18-alpine root down to what the demo runs.
  It keeps Postgres, the tools minipg runs, and their libraries, and
  drops ICU's data and the symlinks.
- `profile.sh` is the login shell's banner.
- `index.html` is the page. Its terminal is a tty to the guest, so psql
  and the shell edit lines themselves.

`minipg init` copies the template rather than running initdb, which
takes about 9s instead of 31s under v86.
