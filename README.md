# postgres17-standalone

A single binary that runs PostgreSQL 17. It boots a 32-bit Linux VM in [v86](https://github.com/copy/v86) inside the OS's native webview via [webframe](https://github.com/tractordev/webframe). Postgres's data directory is a host folder shared with the VM over 9P, and the Postgres port is forwarded to the host through a virtual network.

You don't need Docker or a local Postgres install. The webview is hidden and unthrottled, and is the one the OS already has:

| Platform | Needs |
|---|---|
| macOS | Nothing |
| Windows | Edge WebView2 Runtime (preinstalled on Windows 10/11) |
| Linux (glibc) | WebKitGTK 4.1 or 6.0, plus a display or Xvfb |
| Linux (musl, Alpine) | `apk add webkit2gtk-4.1 xvfb`, and the `linux-musl` build |

Debian/Ubuntu: `apt install libwebkit2gtk-4.1-0 xvfb`

On Linux, if neither `DISPLAY` nor `WAYLAND_DISPLAY` is set, it starts its own private Xvfb and shuts it down when it exits.

## Usage

```sh
POSTGRES_PASSWORD=secret postgres17-standalone [-p port] [-debug] [-v] <dataDir>
```

- `dataDir` (required): the host directory used as Postgres's data directory. It is created if it doesn't exist.
- `-p`: the host port to listen on, on all interfaces. Defaults to `5432`.
- `-debug`: show the webview in a window with its web inspector and start a shell in the VM instead of Postgres. Your terminal is attached to the VM console in raw mode, so Ctrl-C goes to the guest; press Ctrl-D to shut down. Closing the window stops the VM without a clean shutdown.
- `-v`: print the version.

Environment variables:

| Variable            | Required | Default    |
|---------------------|----------|------------|
| `POSTGRES_PASSWORD` | yes (not with `-debug`) |            |
| `POSTGRES_USER`     | no       | `postgres` |
| `POSTGRES_DB`       | no       | `postgres` |
| `POSTGRES17_STANDALONE_CACHE_DIR` | no | `<user cache dir>/postgres17-standalone` |

On first run the root image is decompressed into the cache dir. The cached file is named after a hash of the embedded image, so a new version unpacks a fresh copy and deletes the old one.

The VM console output is streamed to stdout. Press Ctrl-C (or send SIGTERM) to shut down cleanly: Postgres does a fast shutdown and the data image is unmounted before exit. Press Ctrl-C again to force an immediate exit.

```sh
psql -h localhost -U postgres
```

## Docker

The [Dockerfile](Dockerfile) builds an Alpine image with WebKitGTK and Xvfb:

```sh
docker build -t postgres17-standalone .
docker run --rm -p 5432:5432 -e POSTGRES_PASSWORD=secret \
  -v pgdata:/data --stop-timeout 60 postgres17-standalone
```

It runs as a non-root user with the data directory at `/data`, and `docker stop` shuts Postgres down cleanly.

## Building

```sh
make build                              # build assets and ./postgres17-standalone
make build OS=linux-musl GOARCH=arm64   # musl build for Alpine
make assets                             # build root.tar.br and bzImage via Docker
make dist VERSION=v0.3                  # dist/postgres17-standalone_v0.3_<os>_<arch>.zip for all targets
```

Builds use `CGO_ENABLED=0` and cross-compile from anywhere with plain Go. The system webview is loaded at runtime via [purego](https://github.com/ebitengine/purego). The Linux binary still depends on the system's glibc and its loader, which every glibc distro provides.

The exception is `linux-musl` for Alpine. purego without cgo only works with glibc, so that build uses cgo against musl and cross-compiles with [zig](https://ziglang.org) (`zig cc`). You only need zig to build those targets.

## Testing

`.dev/vm` uses [Lima](https://lima-vm.io) to run postgres17-standalone and a set of end-to-end tests on real VMs: Ubuntu, Alpine, macOS 15, and Windows 11 ARM64.

```sh
.dev/vm up linux               # create/start postgres17-linux
.dev/vm test                   # build, copy, and run the tests on every running VM
.dev/vm run macos data         # run it in a VM; POSTGRES_* env passes through
.dev/vm status | shell | down | rm
```

The tests ([.dev/pgtest](.dev/pgtest)) boot Postgres, query it, check the data directory lock, shut down with an interrupt, and boot again to check the data persisted. The macOS and Windows VMs set up auto-login, since the web view needs a desktop session. On Windows, a small Go helper ([.dev/winrun](.dev/winrun)) runs programs in that session through a scheduled task. It's used instead of PowerShell, which takes about 20 seconds to start in the ARM64 guest.

Lima's Windows support is experimental, and the first install needs some manual steps in the VM display. They're listed in [.dev/lima/windows.yaml](.dev/lima/windows.yaml).

## License

MIT
