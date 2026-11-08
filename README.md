# postgres17-standalone

A single binary that runs PostgreSQL 17. It embeds Docker Hub's `postgres:17-alpine` image and runs it with [hyper9](https://github.com/progrium/hyper9) (h9), used as a Zig library. h9's Linux personality runs Alpine's own `postgres` binaries directly on the host's hypervisor, with h9's Plan 9 kernel answering their system calls. There's no Linux kernel to boot, no VM image, no webview, and no Docker.

The image's `docker-entrypoint.sh` sets up the cluster on first run exactly as the Docker image does, so `POSTGRES_PASSWORD`, `POSTGRES_USER`, `POSTGRES_DB` and friends mean what they mean there.

| Platform | Backend | Needs |
|---|---|---|
| Linux x86_64 | KVM, or h9's native backend without it | Linux 5.11 or later; nothing else |
| Linux arm64 | KVM | read/write access to `/dev/kvm` |
| macOS (Apple Silicon) | Hypervisor.framework | Nothing |

Linux builds are static musl binaries, so the same binary runs on glibc distros and Alpine. Windows isn't supported yet: h9 has no Windows hypervisor backend.

> **Proof of concept.** h9 is a research prototype and its Linux personality is young. This is a demonstration of running a real Linux service on it, not a production database.

## Usage

```sh
POSTGRES_PASSWORD=secret postgres17-standalone [-p port] [-debug] [-v] <dataDir>
```

- `dataDir` (required): the host directory that holds the data. It is created if it doesn't exist. Postgres's data directory (`PGDATA`) is its `pgdata` subdirectory, as ordinary host files.
- `-p`: the port Postgres listens on, on all interfaces. Defaults to `5432`. Postgres uses the host's own network stack, so there's no port forwarding.
- `-debug`: start a shell in the Alpine root instead of Postgres, with the data directory at `/mnt/term/cwd`.
- `-v`: print the version.

Environment variables:

| Variable            | Required | Default    |
|---------------------|----------|------------|
| `POSTGRES_PASSWORD` | yes (not with `-debug`) |            |
| `POSTGRES_USER`     | no       | `postgres` |
| `POSTGRES_DB`       | no       | `postgres` |
| `POSTGRES_INITDB_ARGS`, `POSTGRES_INITDB_WALDIR`, `POSTGRES_HOST_AUTH_METHOD`, `TZ` | no | passed to the image as in Docker |
| `POSTGRES17_STANDALONE_CACHE_DIR` | no | `<user cache dir>/postgres17-standalone` |

On first run the root image is unpacked into the cache dir (about 90 MB, a few seconds). The directory is named after a hash of the embedded image, so a new version unpacks a fresh copy and deletes the old one.

Only one instance can use a data directory at a time. Postgres's output is streamed to stdout. Press Ctrl-C (or send SIGTERM) to shut down cleanly: Postgres does a fast shutdown. Press Ctrl-C again, or wait 30 seconds, to force an immediate exit; Postgres recovers from its WAL on the next start.

```sh
psql -h localhost -U postgres
```

## How it works

[src/main.zig](src/main.zig) is the whole program:

1. It locks `<dataDir>/.lock` and unpacks the embedded root ([scripts/root.sh](scripts/root.sh) builds it) into the cache dir.
2. It creates an `h9.Machine` with that tree as its Linux root, the data directory as its writable cwd (`/mnt/term/cwd` in the guest), the network enabled so Postgres can listen on host ports, and the image's environment plus `PGDATA` and `PGPORT`.
3. It runs `/usr/local/bin/docker-entrypoint.sh postgres` in the machine. Writes to the root, such as the socket in `/var/run/postgresql`, go to an overlay in memory; only the data directory persists.
4. SIGINT and SIGTERM post an `interrupt` note, which the Linux personality delivers to Postgres as SIGINT, a fast shutdown. A second signal stops the machine.

[src/host.zig](src/host.zig) is the host side of the console and signals (adapted from h9's CLI), and [src/cli.zig](src/cli.zig) parses the flags.

## Building

Requires [Zig 0.16](https://ziglang.org/download/), and for the root image `curl`, `jq`, GNU `tar` and `xz`. hyper9 is a git submodule, since it can't be fetched as a Zig package yet:

```sh
git submodule update --init
make build                       # pulls the root for this host's arch, builds ./postgres17-standalone
make build OS=linux ARCH=arm64   # cross-compile (OS: linux, macos; ARCH: amd64, arm64)
make root ARCH=arm64             # just assets/root-arm64.tar.xz
make dist VERSION=v0.3           # dist/postgres17-standalone_v0.3_<os>_<arch>.zip
make test                        # unit tests
```

`zig build` works directly too, once `assets/root-<arch>.tar.xz` exists; `-Droot=FILE` embeds another tarball. macOS builds have to be made on a Mac (for the SDK's Hypervisor framework) and are ad-hoc signed with [h9.entitlements](h9.entitlements).

`scripts/root.sh` pulls the image from Docker Hub's registry and drops what a server doesn't need (LLVM for JIT, headers, docs), which takes the compressed root from 77 MB to 22 MB. With `ROOT_DIR` set to an unpacked image tree (`docker export` output, for one) it skips the pull.

## Testing

[.dev/pgtest](.dev/pgtest) boots Postgres, queries it, checks the data directory lock, shuts down with an interrupt, and boots again to check the data persisted. Build it next to the binary and run it:

```sh
(cd .dev/pgtest && go build -o ../../pgtest .) && ./pgtest
```

`.dev/vm` uses [Lima](https://lima-vm.io) to run the same tests on Ubuntu, Alpine and macOS VMs (`.dev/vm up linux`, `.dev/vm test`).

## Docker

The [Dockerfile](Dockerfile) builds an Alpine image with the binary. It hasn't been tested with this version: without `/dev/kvm` in the container, h9's native backend needs a seccomp profile that allows Syscall User Dispatch.

## License

MIT
