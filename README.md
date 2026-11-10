# minipg

PostgreSQL as a file. One binary, nothing to install or configure: a `.pgdb` is the database, and `minipg app.pgdb` opens a shell on it.

```sh
minipg app.pgdb                          # psql shell (creates app.pgdb if missing)
minipg app.pgdb "select 1"               # one statement
minipg url app.pgdb                      # postgres://postgres:...@127.0.0.1:54321/app for your app
minipg serve app.pgdb                    # an explicit foreground server
minipg run app.pgdb -- npm start         # your app, with DATABASE_URL set
minipg dump app.pgdb > dump.sql          # and minipg restore app.pgdb dump.sql
```

minipg embeds Docker Hub's `postgres:18-alpine` image and runs it with [hyper9](https://github.com/progrium/hyper9) (h9), used as a Zig library. h9's Linux personality runs Alpine's own Postgres binaries directly on the host's hypervisor, with h9's Plan 9 kernel answering their system calls. There's no Linux kernel to boot, no VM image, and no Docker.

> **Early.** h9 is a research prototype and its Linux personality is young. See [Known limits](#known-limits) before trusting it with data you can't recreate.

The **[manual](MANUAL.md)** is the full guide: concepts, everyday tasks, backup and restore, Postgres versions, CI, performance, durability, troubleshooting, and a reference for every command, variable, and file.

## The .pgdb

A `.pgdb` is a directory:

```
app.pgdb/
  minipg.toml   settings and the generated superuser password (mode 0600)
  pgdata/       Postgres's data directory, as plain files
  .lock         held by the server while it runs
```

Data, config, credentials, and the Postgres version live inside it; nothing is written next to it. A stopped `.pgdb` can be copied like any directory. While a server runs, use `pg_dump` (`minipg exec app.pgdb -- pg_dump`), since a raw copy isn't guaranteed consistent.

`minipg.toml` records the layout `format`, the Postgres major, variant (alpine), arch, and image digest, the superuser and its generated password, the default database (named after the file: `app.pgdb` has `app`), and the preferred port, picked at init.

New clusters use Postgres's builtin `C.UTF-8` locale, which sorts the same on every platform and never changes between versions, so indexes on text can't be invalidated by a libc update.

## Commands

Every command takes the `.pgdb` first; a bare path is shorthand for `shell`. `-d DB` picks another database.

| Command | What it does |
|---|---|
| `minipg <pgdb> [sql]`, `shell <pgdb\|url> [sql]` | psql on the `.pgdb` (or any `postgres://` URL), or run the statements given |
| `init <pgdb> [--port N] [--user U]` | Create a `.pgdb` and initialize its cluster (about 4s); refuses if the path exists |
| `serve <pgdb> [-p PORT] [--listen ADDR] [--log FILE] [--trust] [-- postgres args]` | Run the server in the foreground; Ctrl-C stops it |
| `stop <pgdb>` | Stop its server cleanly |
| `status <pgdb>` | Running or not, port, clients, uptime; exits 3 when stopped |
| `url <pgdb>` | A `postgres://` URL with the password |
| `logs <pgdb> [-f]` | The server's recent log (a 4 MB window), or the last server's log file |
| `exec <pgdb> -- TOOL [args]` | Run a Postgres tool (pg_dump, pg_restore, psql, ...) against the server, with `PG*` set |
| `env <pgdb>` | `DATABASE_URL` and `PG*` as shell exports: `eval "$(minipg env app.pgdb)"`; on Windows, PowerShell assignments: `minipg env app.pgdb \| Invoke-Expression` |
| `run <pgdb> -- CMD [args]` | Run a host command with `DATABASE_URL` and `PG*` set; the server stays up until it exits, and its exit code is minipg's |
| `dump <pgdb> [pg_dump args]` | `pg_dump` to stdout (plain SQL unless args say otherwise) |
| `restore <pgdb> [FILE]` | Restore a plain SQL or custom-format dump from FILE or stdin; stops at the first error |
| `dbs <pgdb>` | List databases, the default marked `*` |
| `create <pgdb> NAME`, `drop <pgdb> NAME` | Create or drop a database; the default can't be dropped |
| `default <pgdb> [NAME]` | Show or set the default database (what `url`, `shell`, and the rest use) |
| `passwd <pgdb>` | Give the superuser a new generated password (or `POSTGRES_PASSWORD`) and save it |
| `versions` | Postgres versions embedded and downloaded |
| `fetch MAJOR` | Download a Postgres major's root (`postgres:MAJOR-alpine`) |
| `prune` | Remove downloaded roots; they come back on demand |

`shell`, `url`, `env`, `run`, `restore`, and the bare form create a missing `.pgdb` with defaults. `init` takes `POSTGRES_USER`, `POSTGRES_PASSWORD`, and `POSTGRES_DB` as defaults, and passes `POSTGRES_INITDB_ARGS`, `POSTGRES_INITDB_WALDIR`, and `TZ` through to the image as Docker would.

### Other Postgres majors

The binary embeds one major (18 by default). `init --pg 17` makes a `.pgdb` on another, downloading `postgres:17-alpine` from Docker Hub for this host's arch, trimming it as the build does, and caching it by digest. A `.pgdb` remembers its major, and opening one whose root isn't cached downloads it again. `MINIPG_OFFLINE=1` turns downloads off, and `MINIPG_REGISTRY` names another registry (`host`, or `host/repository`). Downloads honor `HTTPS_PROXY`, `NO_PROXY`, and `SSL_CERT_FILE`.

### Servers

Exactly one process runs Postgres for a `.pgdb`, enforced by the lock. Commands never host Postgres themselves: if no server is running, they start one in the background and use it. Back-to-back commands share it, and it stops after `MINIPG_IDLE` seconds (default 60) without client connections. `serve` runs one in the foreground with no idle timeout.

Postgres listens on a host port directly, on `127.0.0.1` unless `--listen` says otherwise. The port stored at init is used when it's free; otherwise the server picks another, and `url` reports the one in use. Apps authenticate with SCRAM and the generated password, loopback included (initdb's default would trust it). `serve --trust` lets loopback clients in without one, and is refused with a non-loopback `--listen`.

psql, pg_dump, and the other tools run in their own short-lived h9 machine (about 90 ms to start) over the same root, and connect to the server over loopback. Their working directory is yours, so `pg_dump -f dump.sql` writes where you are.

### Files outside the .pgdb

| What | Linux | macOS | Windows |
|---|---|---|---|
| Runtime (run.json, control socket) | `$XDG_RUNTIME_DIR/minipg/<key>/` | `$TMPDIR/minipg-$UID/<key>/` | `%LOCALAPPDATA%\minipg\run\<key>\` |
| Logs | `~/.local/state/minipg/logs/<key>.log` | `~/Library/Logs/minipg/<key>.log` | `%LOCALAPPDATA%\minipg\logs\<key>.log` |
| Unpacked roots | `~/.cache/minipg/roots/<digest>/` | `~/Library/Caches/minipg/roots/<digest>/` | `%LOCALAPPDATA%\minipg\roots\<digest>\` |

`<key>` is a hash of the `.pgdb` directory's device and inode (on Windows, its volume and file index). Linux falls back to `~/.cache/minipg/run/` without `XDG_RUNTIME_DIR`, and honors `XDG_STATE_HOME` and `XDG_CACHE_HOME`. The first run unpacks the embedded root (about 90 MB, a few seconds).

## Platforms

| Platform | h9 backend | Needs | Tested |
|---|---|---|---|
| Linux x86_64 | KVM, or h9's native backend without it | Linux 5.11 or later | Yes, native backend |
| Linux arm64 | KVM | read/write `/dev/kvm` | Builds; not run |
| macOS (Apple Silicon) | Hypervisor.framework | the hypervisor entitlement (the build signs ad hoc) | Not run |
| Windows x86_64 | Windows Hypervisor Platform (WHP) | Windows 10 1803 or later, with the Windows Hypervisor Platform feature on | Yes, on WHP |

Linux builds are static musl binaries, so one runs on glibc distros and Alpine alike. Windows on ARM isn't supported yet: h9 has no WHP backend for arm64, and minipg leaves out h9's emulator, which is GPL-licensed.

On Windows, turn the feature on in Settings > System > Optional features > More Windows features ("Windows Hypervisor Platform"), or with `DISM /Online /Enable-Feature /FeatureName:HypervisorPlatform` as an administrator, then restart.

## In containers and CI

Nothing needs installing or privileges: the Linux binary is static, and without `/dev/kvm` h9 runs Postgres on its native backend, which needs Linux 5.11 or later and nothing else (no `--privileged`, no devices). minipg's own e2e suite runs that way in CI, on stock GitHub runners. The first command unpacks the root into the cache directory, so mount or cache `~/.cache/minipg` to skip that on later runs. A test job can be as small as:

```sh
minipg init test.pgdb
minipg run test.pgdb -- go test ./...
```

## How it works

- [src/server.zig](src/server.zig) is the server process. It holds the `.pgdb`'s lock, picks the port, writes `run.json`, serves the control socket, and runs Postgres in an h9 machine whose Linux root is the unpacked image and whose writable cwd is the `.pgdb` (`/mnt/term/cwd` in the guest). The image's `docker-entrypoint.sh` initializes the cluster on first start. A monitor thread logs in to see when Postgres is ready, then counts clients in `pg_stat_activity` for `status` and the idle timeout.
- To stop, the server tells a small supervisor shell in the machine, which sends SIGINT (a fast shutdown) to the postmaster alone. h9's interrupt note would reach every process in the machine, and Postgres's children act on SIGINT themselves, which can leave the postmaster waiting forever. A second Ctrl-C, or 30 seconds, tears the machine down; Postgres recovers from its WAL on the next start.
- [src/control.zig](src/control.zig) is the control protocol: one versioned request line over a unix socket, AF_UNIX on Windows too (`status`, `stop`, `logs [follow]`, `clients`).
- [src/client.zig](src/client.zig) finds a running server or starts one; [src/vm.zig](src/vm.zig) builds the server and tool machines; [src/pgwire.zig](src/pgwire.zig) is the small Postgres client (SCRAM-SHA-256, simple queries) the server uses on the host.

## Building

Requires [Zig 0.16](https://ziglang.org/download/), and for the root `curl`, `jq`, `tar`, and `xz`. hyper9 is a git submodule, since it can't be fetched as a Zig package yet:

```sh
git submodule update --init
make build                       # pulls the root for this host's arch, builds ./minipg
make build OS=linux ARCH=arm64   # cross-compile (OS: linux, macos, windows; ARCH: amd64, arm64)
make build OS=windows ARCH=amd64 # ./minipg.exe
make root ARCH=arm64             # just assets/root-arm64.tar.xz and .json
make build PG_MAJOR=17           # embed another major
make dist VERSION=v0.4           # dist/minipg_v0.4_<os>_<arch>.zip
```

[scripts/root.sh](scripts/root.sh) pulls the image from Docker Hub's registry, drops what a server doesn't need (LLVM for JIT, headers, docs), and records the image's digest, version, and ENV beside the tarball. JIT is therefore unavailable, and minipg sets `jit=off`. macOS builds have to be made on a Mac (for the SDK's Hypervisor framework). Windows builds cross-compile from anywhere; on Windows itself, run root.sh from Git Bash or MSYS2.

## Testing

```sh
make test     # unit tests
make e2e      # builds ./minipg, then drives it end to end (.dev/e2e, Go)
make stress   # the slow stress suite: kill -9 mid-write, soak, limits, recovery
```

## Known limits

- **Speed.** On h9's native backend (x86_64 Linux without KVM), Postgres is about 2x slower than native for one client and 6 to 12x under load, and a new connection costs about 27 ms. Apps that don't pool connections will feel it. KVM and HVF haven't been measured.
- **Killed servers.** On the native backend each Postgres process is its own host process. If the server process is killed outright (SIGKILL, OOM), they live on for a few seconds before exiting, and the `.pgdb` stays locked until they do; minipg waits for that. Postgres recovers from its WAL on the next start.
- **pg_restore from a pipe.** pg_restore misreads a custom-format archive on stdin inside h9, so `minipg restore` spools stdin to a temp file first.
- **Cross-arch.** A `.pgdb` records the arch it was created on, and the server warns when it's opened on another.
- **Windows roots.** Windows lets only administrators (or Developer Mode) make symlinks, so on Windows the root's symlinks are unpacked as hard links to their targets, and its few directory links as copies.
- **Windows memory.** WHP commits a machine's whole guest memory up front: 2 GB for each server and 1 GB for each running tool. On an 8 GB machine, three or four servers at once is the limit, and the page file grows with them.

## License

MIT
