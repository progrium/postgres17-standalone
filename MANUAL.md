# minipg manual

This is the long-form guide to minipg. The [README](README.md) is the short version: what minipg is, a command table, and how to build it. This manual covers how minipg behaves, how to use it day to day, and what every command, variable, and file does.

## Contents

1. [Introduction](#1-introduction)
2. [Installing](#2-installing)
3. [Quick start](#3-quick-start)
4. [Concepts](#4-concepts)
5. [Everyday tasks](#5-everyday-tasks)
6. [Running a server explicitly](#6-running-a-server-explicitly)
7. [Backup, restore, and copying](#7-backup-restore-and-copying)
8. [Postgres versions](#8-postgres-versions)
9. [Containers and CI](#9-containers-and-ci)
10. [Performance](#10-performance)
11. [Durability and safety](#11-durability-and-safety)
12. [Troubleshooting](#12-troubleshooting)
13. [Reference](#13-reference)
- [Appendix A: How it works](#appendix-a-how-it-works)
- [Appendix B: Building from source](#appendix-b-building-from-source)
- [Appendix C: Roadmap](#appendix-c-roadmap)

---

## 1. Introduction

minipg gives PostgreSQL the workflow of SQLite. It's one binary with nothing to install or configure, and a `.pgdb` is the database: `minipg app.pgdb` creates it if needed, starts Postgres, and opens a psql shell on it.

Under the hood, minipg embeds Docker Hub's official `postgres:18-alpine` image and runs Alpine's own Postgres binaries with [hyper9](https://github.com/progrium/hyper9) (h9). h9's Linux personality executes them directly on the host's hypervisor, with h9's Plan 9 kernel answering their system calls. There's no Linux kernel to boot, no VM image, and no Docker.

**Who it's for.** People who would use SQLite but need Postgres, software that wants to ship its own Postgres, and test suites and CI jobs that need a real Postgres without setting one up. It isn't for workloads that need scale, high availability, or production operations; run Postgres normally or in a container for those.

minipg makes four promises:

- **The .pgdb is the database.** Data, settings, credentials, and the Postgres version all live inside it. Nothing is written next to it.
- **No server to manage.** Servers start on demand, are shared by commands that run at the same time, and stop on their own when idle. `serve` exists for when you want one explicitly.
- **No credentials to handle.** A password is generated and stored in the `.pgdb`, and `url`, `env`, and `run` hand it to your apps.
- **Works offline.** The default Postgres major is embedded in the binary. Other majors download on demand and are cached.

> **Early software.** h9 is a research prototype, and its Linux personality is young. Read [Durability and safety](#11-durability-and-safety) and [Performance](#10-performance) before trusting minipg with data you can't recreate.

## 2. Installing

Download the zip for your platform from the releases page, unzip it, and put `minipg` somewhere on your `PATH`. Release zips are named `minipg_<version>_<os>_<arch>.zip`.

| Platform | h9 backend | Needs | Tested |
|---|---|---|---|
| Linux x86_64 | KVM, or h9's native backend without it | Linux 5.11 or later | Yes, on the native backend |
| Linux arm64 | KVM | Read and write access to `/dev/kvm` | Builds; not run |
| macOS (Apple Silicon) | Hypervisor.framework | The hypervisor entitlement (release builds are signed ad hoc with it) | Builds; not run |

Linux builds are static musl binaries, so the same binary runs on glibc distros, Alpine, and minimal container images. Intel Macs and Windows aren't supported yet.

On macOS, a binary downloaded with a browser may be quarantined by Gatekeeper. If macOS refuses to run it, clear the quarantine attribute with `xattr -d com.apple.quarantine ./minipg`.

Check the install with:

```sh
minipg --version
minipg --help
```

The first command that needs Postgres unpacks the embedded root (the Alpine userland, about 90 MB) into the cache directory. That takes a few seconds and happens once per Postgres build. See [Files outside the .pgdb](#134-files-outside-the-pgdb) for where it goes.

To build from source instead, see [Appendix B](#appendix-b-building-from-source).

## 3. Quick start

Open a shell on a new database:

```sh
minipg app.pgdb
```

minipg prints `creating app.pgdb`, initializes a Postgres cluster in it (a few seconds the first time), starts a server in the background, and drops you into psql connected to the `app` database. Quit psql with `\q`; the server keeps running for a minute in case you come back, then stops.

Run one statement without the interactive shell:

```sh
minipg app.pgdb "create table notes (id serial primary key, body text)"
minipg app.pgdb "insert into notes (body) values ('hello')"
minipg app.pgdb "select * from notes"
```

Connect an app:

```sh
minipg url app.pgdb                  # postgres://postgres:...@127.0.0.1:54321/app
minipg run app.pgdb -- npm start     # npm start, with DATABASE_URL and PG* set
```

Back it up and restore it:

```sh
minipg dump app.pgdb > backup.sql
minipg restore copy.pgdb backup.sql
```

Stop the server, if you don't want to wait for the idle timeout:

```sh
minipg stop app.pgdb
```

## 4. Concepts

### 4.1 The .pgdb

A `.pgdb` is a directory that holds one Postgres cluster along with everything needed to run it:

```
app.pgdb/
  minipg.toml   settings and the generated superuser password (mode 0600)
  pgdata/       Postgres's data directory, as plain files
  .lock         held by the server while it runs
```

minipg treats a directory as a `.pgdb` when it contains `minipg.toml`. The `.pgdb` suffix is a convention, not a requirement, but it's what makes the default database name come out right (see below).

`minipg.toml` records the layout format, the Postgres major, variant (always `alpine`), architecture, and image digest the cluster was created with, the superuser and its password, the default database, and the preferred port. Every key is described in [minipg.toml](#133-minipgtoml).

The **default database** is named after the file: `app.pgdb` gets a database called `app`, and `/data/orders.pgdb` gets `orders`. Commands connect to the default database unless you pass `-d DB`, and `minipg default` changes which one is the default.

Plain files grow and shrink with the host filesystem, so there's nothing to size or resize.

### 4.2 Servers

Exactly one process runs Postgres for a given `.pgdb`. That process is the **server**, and it holds an exclusive lock on `.lock` for its whole life. The operating system releases the lock if the process dies, even on `kill -9`.

Commands never host Postgres themselves. When a command needs Postgres, it looks for a running server. If there isn't one, it starts a **background server** and waits for it to be ready. Back-to-back commands share that server, and so do commands running at the same time. The server counts client connections, and after `MINIPG_IDLE` seconds (default 60) with none, it shuts down cleanly.

`minipg serve` runs a server in the foreground instead, with its log on your terminal and no idle timeout. Use it when you want a server's lifetime under your control: in development, under a process supervisor, or in a container. See [Running a server explicitly](#6-running-a-server-explicitly).

**Ports.** `init` picks a free port and stores it in `minipg.toml` as the preferred port. Each time a server starts, it uses that port if it's free, or else picks another free one and logs `port N is taken; using M instead`. So a URL you saved usually keeps working, and `minipg url` always reports the port actually in use.

**Listen address.** Postgres binds the host port directly, on `127.0.0.1` unless `serve --listen` says otherwise. There's no proxy in between.

### 4.3 Tools run in their own machine

psql, pg_dump, pg_restore, and the other Postgres tools aren't installed on your host; they come from the same Alpine root as the server. When minipg runs one (for `shell`, `exec`, `dump`, or `restore`), it starts a fresh, short-lived h9 machine for it, which takes about 90 ms, and the tool connects to the server over loopback like any other client.

The tool's working directory is yours, so file paths behave as you'd expect: `minipg exec app.pgdb -- pg_dump -f dump.sql` writes `dump.sql` where you ran it, and `\i schema.sql` in the shell reads it from there.

### 4.4 Credentials

`init` generates a random password for the superuser (`postgres` by default) and stores it in `minipg.toml`, which is readable only by you (mode 0600). Every TCP connection uses SCRAM-SHA-256 with that password, loopback included. Postgres's own initdb would trust loopback connections, but on a shared machine that would let any local user in, so minipg turns it off.

You rarely need to see the password. `url`, `env`, and `run` hand it to apps, and `shell`, `exec`, `dump`, and `restore` pass it to the tools for you. `passwd` rotates it. `serve --trust` lets loopback clients in without a password, when you'd rather not have one at all.

## 5. Everyday tasks

### Opening a shell

```sh
minipg app.pgdb                  # psql on the default database
minipg app.pgdb -d other         # on another database in the same .pgdb
minipg shell app.pgdb            # the same as the bare form
```

The bare form and `shell` create the `.pgdb` if it doesn't exist. `shell` also accepts a `postgres://` URL in place of a `.pgdb`, which runs the embedded psql against any Postgres server:

```sh
minipg shell postgres://user:pass@db.example.com/prod
```

### Running SQL

Each extra argument is one statement, run with `psql -c`:

```sh
minipg app.pgdb "select count(*) from notes"
minipg app.pgdb "begin" "update notes set body = upper(body)" "commit"
```

To run a file, use psql's `-f` after `--`, or pipe it in:

```sh
minipg app.pgdb -- -f schema.sql
minipg app.pgdb < schema.sql
```

Anything after `--` is passed to psql, so its other flags work too, such as `-- -At -c "select 1"` for unaligned, tuples-only output in scripts.

### Connecting an app

There are three ways to hand connection details to an app, from most to least automatic.

**`run`** starts the server if needed, runs your command with `DATABASE_URL`, `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, and `PGDATABASE` set, and keeps the server up until the command exits, whether or not it has connected yet. minipg exits with the command's exit code.

```sh
minipg run app.pgdb -- npm start
minipg run app.pgdb -d test -- pytest
```

**`env`** prints the same variables as shell exports:

```sh
eval "$(minipg env app.pgdb)"
```

**`url`** prints just the URL, for a config file or a `.env`:

```sh
minipg url app.pgdb
minipg url app.pgdb -d analytics
```

`url` and `env` don't start a server. When one is running, they report its port; otherwise they report the preferred port, which the next server will use if it's free. With `url` or `env`, start the server separately (with `serve`, or with any command that needs Postgres) before your app connects. `run` takes care of that for you.

### Working with several databases

A `.pgdb` holds a whole Postgres cluster, so it can have many databases:

```sh
minipg dbs app.pgdb              # list them, with sizes; * marks the default
minipg create app.pgdb test      # create one
minipg drop app.pgdb test        # drop one
minipg default app.pgdb          # show the default
minipg default app.pgdb test     # make test the default
```

The default database can't be dropped; make another one the default first. Roles are cluster-wide, as in any Postgres.

### Running any Postgres tool

`exec` runs any tool from the Postgres image against the server, with the `PG*` variables set so it connects without arguments:

```sh
minipg exec app.pgdb -- pg_dump -Fc -f app.dump
minipg exec app.pgdb -- pgbench -i -s 10
minipg exec app.pgdb -- vacuumdb --analyze
```

The tool runs in its own machine (see [Tools run in their own machine](#43-tools-run-in-their-own-machine)), not on your host, so it's always the version that matches the server.

### Reading logs

```sh
minipg logs app.pgdb             # the running server's recent log
minipg logs app.pgdb -f          # and follow it
```

A running server keeps the most recent 4 MB of output in memory, and `logs` prints that window. With no server running, `logs` prints the last server's log file instead. The full log of each run is written to a per-`.pgdb` log file (see [Files outside the .pgdb](#134-files-outside-the-pgdb)), or to the file you name with `serve --log FILE`.

### Checking on a server

```sh
minipg status app.pgdb
```

For a running server, `status` prints its Postgres version, listen address and port, pid, client count, uptime, when it will stop if idle, and the minipg version. For a stopped one, it prints the Postgres version last opened and the preferred port, and exits with code 3, so scripts can test for a running server:

```sh
if minipg status app.pgdb > /dev/null; then echo running; fi
```

### Rotating the password

```sh
minipg passwd app.pgdb
POSTGRES_PASSWORD=hunter2 minipg passwd app.pgdb    # set a specific one
```

`passwd` changes the superuser's password in Postgres and saves it in `minipg.toml`. Sessions already connected keep working, but new connections need the new password, so get a fresh URL with `minipg url` and restart your apps. If saving `minipg.toml` fails after the password has changed, minipg prints the new password so it isn't lost.

### Changing Postgres settings

There are two ways to set Postgres configuration parameters:

- For one server run, pass them to `serve` after `--`: `minipg serve app.pgdb -- -c shared_buffers=256MB -c log_statement=all`.
- To keep them, use `ALTER SYSTEM` from a shell, which writes `pgdata/postgresql.auto.conf` inside the `.pgdb`, then restart the server: `minipg app.pgdb "alter system set work_mem = '64MB'"`, then `minipg stop app.pgdb`.

minipg always starts Postgres with `listen_addresses`, `port`, and `jit=off` on the command line, so those three can't be changed with `ALTER SYSTEM`. Use `serve --listen` and `serve -p` for the first two.

## 6. Running a server explicitly

```sh
minipg serve app.pgdb [-p PORT] [--listen ADDR] [--log FILE] [--trust] [--idle SECONDS] [-- postgres args]
```

`serve` runs the server in the foreground and echoes its log to your terminal. It has no idle timeout unless you give it `--idle`. While it runs, every other command for that `.pgdb` uses it.

| Flag | What it does |
|---|---|
| `-p PORT`, `--port PORT` | Use this port, and fail if it's taken, instead of the preferred port with a fallback |
| `--listen ADDR` | Listen on this address instead of `127.0.0.1`, such as `0.0.0.0` for every interface |
| `--log FILE` | Write the full log to FILE instead of the default log file |
| `--trust` | Let loopback clients connect without a password |
| `--idle SECONDS` | Stop after this many seconds without clients, as a background server does |
| `-- ARGS` | Pass the remaining arguments to the `postgres` command, such as `-c name=value` |

**Listening beyond loopback.** With `--listen 0.0.0.0` (or a specific interface address), anyone who can reach the port can try to connect. They still need the password, since SCRAM applies to every TCP connection. `url` and `env` keep reporting a loopback host, so give remote clients the machine's own address.

**`--trust`.** minipg writes a temporary access file that trusts connections from `127.0.0.1` and `::1`, and removes it when the server stops. `--trust` is refused with a non-loopback `--listen`, because it would let anyone who can reach the port in without a password.

**Stopping.** Ctrl-C, SIGTERM, and `minipg stop` all ask Postgres for a fast shutdown: open transactions are rolled back, clients are disconnected, and Postgres writes a checkpoint before exiting. A second Ctrl-C, or 30 seconds without an exit, tears the machine down at once; Postgres then recovers from its write-ahead log (WAL) on the next start, with no committed data lost.

**Under a supervisor.** `serve` is a normal foreground process, which suits systemd, launchd, a Procfile, or a container's entrypoint. A systemd unit can be as small as this:

```ini
[Service]
ExecStart=/usr/local/bin/minipg serve /var/lib/app/app.pgdb
KillSignal=SIGTERM
TimeoutStopSec=40
```

## 7. Backup, restore, and copying

### Dumping

```sh
minipg dump app.pgdb > app.sql             # plain SQL
minipg dump app.pgdb -Fc > app.dump        # custom format
minipg dump app.pgdb -d other > other.sql  # another database
```

`dump` runs `pg_dump` on the default database (or the one named with `-d`) and writes to stdout. Any other arguments go to pg_dump, so its options for formats, schemas, tables, and data-only dumps all work.

### Restoring

```sh
minipg restore app.pgdb app.sql
minipg restore app.pgdb app.dump
minipg restore app.pgdb < app.sql
minipg restore new.pgdb app.sql            # creates new.pgdb first
```

`restore` reads a plain SQL dump or a custom-format dump from FILE, or from stdin when no file is named. It tells them apart by the first bytes, so there's no flag for the format. It restores into the default database or the one named with `-d`, and creates the `.pgdb` if it doesn't exist.

Restores stop at the first error, and minipg exits non-zero. A plain SQL dump runs through psql with `ON_ERROR_STOP`, and its query output is discarded. A custom-format dump runs through pg_restore with `--no-owner`, `--no-acl`, and `--exit-on-error`, so ownership and privileges from the source don't need matching roles here. A custom-format dump on stdin is spooled to a temporary file first, since pg_restore misreads one from a pipe inside h9.

For a clean restore into an existing database, drop and recreate it first, or restore into a new `.pgdb`.

### Copying a .pgdb

A **stopped** `.pgdb` is an ordinary directory. Copy, move, archive, or sync it with any tool: `cp -r`, `mv`, `rsync`, `tar`, or `zip`. Check that it's stopped with `minipg status` (exit code 3), and stop it with `minipg stop` if not.

Don't copy a **running** `.pgdb` this way. Postgres is writing its files as you copy them, so the copy isn't guaranteed to be consistent. Use `dump` while a server runs.

### Moving between machines

A `.pgdb` moves between machines of the same architecture like any directory. It records the architecture it was created on (`pg.arch`), and a server opened on a different one logs a warning: x86_64 and arm64 are both 64-bit little-endian, so the data files are expected to carry across, but Postgres doesn't promise it. To move a `.pgdb` across architectures safely, dump it on one and restore it on the other.

## 8. Postgres versions

### What's available

Each minipg binary embeds one Postgres major, currently 18, as the root it uses by default. Other majors download from Docker Hub when needed.

```sh
minipg versions     # the embedded version, cached downloads, and where others come from
minipg fetch 17     # download Postgres 17 ahead of time
minipg prune        # remove downloaded roots (never the embedded one)
```

### Creating a .pgdb on another major

```sh
minipg init old.pgdb --pg 17
```

`init --pg MAJOR` uses the newest root for that major, downloading `postgres:MAJOR-alpine` for this host's architecture if it isn't cached. minipg trims the downloaded image the same way the build trims the embedded one and caches it by digest.

A `.pgdb` remembers its major. Opening one whose root isn't cached, such as after `prune` or on a new machine, downloads it again automatically. If it can't be downloaded, the command fails and the error names `minipg fetch MAJOR`.

### Downloading offline, through a proxy, or from a mirror

- `MINIPG_OFFLINE=1` turns downloads off. Commands that would download fail instead, naming what's missing.
- `MINIPG_REGISTRY` points minipg at another registry: `host`, or `host/repository` for a mirror that stores images under another path.
- Downloads honor `HTTPS_PROXY`, `NO_PROXY`, and `SSL_CERT_FILE`.

### Locale and collation

New clusters on Postgres 17 and later use Postgres's builtin `C.UTF-8` locale. It sorts the same on every platform and never changes between versions, so a libc update can't silently invalidate an index on a text column. You can choose another locale at init time with `POSTGRES_INITDB_ARGS` (for example `--locale=en_US.UTF-8`), and then minipg relies on Postgres's own collation versioning.

When a server starts, it checks every database's recorded collation version against the current one. If they differ, it logs a warning naming the database and the fix: run `REINDEX DATABASE` and `ALTER DATABASE ... REFRESH COLLATION VERSION` in it.

### Upgrading to a new major

There's no built-in upgrade command yet. To move a `.pgdb` to a newer major, dump it and restore it into a new `.pgdb`:

```sh
minipg stop app.pgdb
minipg dump app.pgdb -Fc > app.dump
minipg init app-18.pgdb --pg 18
minipg restore app-18.pgdb app.dump
```

Check the new one, then swap the directories. Minor versions (18.4 to 18.5) need no migration; a new minipg release may embed a newer minor, and a downloaded root resolves to the newest minor for its major.

### What's not in the image

minipg trims what a server doesn't need from the image: LLVM, headers, and documentation. Without LLVM there's no JIT compilation, so minipg starts Postgres with `jit=off`. Extensions that ship in the official alpine image, such as `pgcrypto`, `hstore`, and `pg_trgm`, are available with `CREATE EXTENSION`. Third-party extensions aren't, until custom images arrive (see [Roadmap](#appendix-c-roadmap)).

## 9. Containers and CI

minipg needs no installation, no privileges, and no devices in a container. The Linux binary is static, and without `/dev/kvm`, h9 runs Postgres on its native backend, which needs only Linux 5.11 or later. There's no `--privileged`, no `--device`, and no extra capabilities to grant. minipg's own end-to-end tests run this way on stock GitHub runners.

A test job can be as small as this:

```sh
minipg init test.pgdb
minipg run test.pgdb -- go test ./...
```

`run` holds the server open for the whole command and passes its exit code through, so the job fails when the tests do.

The first command unpacks the root into `~/.cache/minipg` (on Linux). Cache that directory between runs to skip the unpack. In GitHub Actions:

```yaml
- uses: actions/cache@v4
  with:
    path: ~/.cache/minipg
    key: minipg-${{ runner.os }}
- run: minipg init test.pgdb
- run: minipg run test.pgdb -- npm test
```

In a Dockerfile, copy the binary in and either `serve` as the entrypoint or use `run` around your app. (minipg's own tests run directly on GitHub's runners; running inside Docker hasn't been tested yet.)

```dockerfile
FROM alpine:3.20
COPY minipg /usr/local/bin/minipg
CMD ["minipg", "run", "/data/app.pgdb", "--", "/app/server"]
```

Tips for test suites:

- Use one `.pgdb` per run, and delete it afterward. `init` takes about 4 seconds; creating a database inside an existing `.pgdb` with `minipg create` is faster for per-test isolation.
- `MINIPG_IDLE` controls how long a background server lingers. A short value (such as 5) frees memory sooner in jobs that run many short commands. A long one avoids restarts between steps.
- Connection setup is slower than native Postgres; see [Performance](#10-performance). A connection pool in your test harness helps more than anything else.

## 10. Performance

These numbers come from x86_64 Linux on h9's native backend (no KVM), compared with the same machine's native Postgres. They're rough, but they set expectations.

| Measure | minipg | Native | Ratio |
|---|---|---|---|
| Single-client select latency | 0.24 ms | 0.11 ms | About 2x |
| Select-only throughput, 4 clients | 3,800 tps | 44,900 tps | About 12x |
| TPC-B-like throughput, 4 clients | 640 tps | 3,900 tps | About 6x |
| New connection | 27 ms | 2.3 ms | About 12x |
| Server start | About 2 s | | |
| First start (unpack and initdb) | About 4 to 8 s | | |

**Use a connection pool.** Each new Postgres connection forks a backend process, and fork is the most expensive thing h9 does. An app that opens a connection per request will feel it; one that holds a pool won't.

**Memory.** An idle server uses about 375 MB of resident memory, and about 550 MB under load, mostly shared guest memory. That's much more than native Postgres with the same settings.

KVM (on Linux) and Hypervisor.framework (on macOS) avoid the native backend's main cost, a cross-thread round trip on every system call, and are expected to be faster. They haven't been measured yet.

## 11. Durability and safety

**What's tested.** minipg's end-to-end suite kills the server with `kill -9` in the middle of writes, restarts it, and checks that Postgres recovers from its WAL and that `amcheck` finds no index corruption. File `fsync` calls, directory `fsync` calls, and `sync` all reach the host's disk, so Postgres's own durability rules hold: a committed transaction survives a crash of minipg or of Postgres.

**What isn't.** Power loss and kernel crashes haven't been tested. Neither KVM, Hypervisor.framework, nor arm64 has been crash-tested yet.

**Killed servers.** On the native backend, each Postgres process is its own host process. If the server process is killed outright (SIGKILL, or the OOM killer), those processes live on for a few seconds before exiting, and the `.pgdb` stays locked until they do. A command that wants a server waits for the lock and then starts one, and Postgres recovers from its WAL.

**Format versions.** `minipg.toml` records the `.pgdb`'s layout format. minipg opens any format at or below its own and refuses a newer one, with an error telling you to upgrade minipg. Format changes that need a migration will come with an explicit command, never a silent rewrite.

**Version mismatches between minipg binaries.** Any minipg can connect to any server as a Postgres client. Only the control socket depends on the minipg version: if a server was started by a minipg whose control protocol differs, commands like `status` and `stop` refuse with both versions named. Stop the server with the minipg that started it, or wait for its idle timeout.

## 12. Troubleshooting

**"waiting for the server for app.pgdb to start..."** The first start unpacks the root and runs initdb, which can take several seconds, longer on a slow disk. Later starts take about 2 seconds. If it never finishes, minipg prints the end of the server's log.

**"the server for app.pgdb failed to start".** minipg prints the last lines of the log. Common causes are a port pinned with `-p` that's taken, a bad `-c` setting passed to `serve`, or a cluster left half-initialized by an interrupted `init`. `minipg logs app.pgdb` shows the full last log.

**"app.pgdb is in use by a running server".** Another server holds the `.pgdb`'s lock. Stop it with `minipg stop`. If a server was killed, wait a few seconds for its processes to exit.

**The URL's port changed.** The preferred port was taken when the server started, so it picked another (the log says `port N is taken; using M instead`). Get the current URL with `minipg url`, or pin a port with `serve -p`.

**"no Postgres 17 root is available".** The `.pgdb` uses a major whose root isn't cached, and it couldn't be downloaded. Run `minipg fetch 17` while online, unset `MINIPG_OFFLINE`, or check your proxy and `MINIPG_REGISTRY` settings.

**"app.pgdb was made by a newer minipg".** Its format is newer than this binary understands. Upgrade minipg.

**"app.pgdb isn't a .pgdb: it has no minipg.toml".** The path exists but isn't a `.pgdb`. minipg won't initialize over an existing directory; pick a new path.

**A warning that the .pgdb was created on another architecture.** See [Moving between machines](#moving-between-machines).

**A warning about a collation version.** Run the `REINDEX DATABASE` and `ALTER DATABASE ... REFRESH COLLATION VERSION` statements the warning names, in the database it names.

**"password authentication failed".** The app has an old password, likely from before a `passwd`. Get a fresh URL with `minipg url`.

**Where to look.** `minipg status` for whether a server is running and on which port, `minipg logs` for its log, and the log file itself (see [Files outside the .pgdb](#134-files-outside-the-pgdb)) for the full history of the last run.

## 13. Reference

### 13.1 Commands

Every command except `versions`, `fetch`, and `prune` takes a `.pgdb` path first. A bare path, as in `minipg app.pgdb`, is shorthand for `shell`.

Flags can come before or after the `.pgdb`, as `-x`, `--name`, `--name=value`, or `--name value`. `--` ends the flags; everything after it goes to the tool or command being run. `-d DB` (or `--db DB`) picks a database other than the default, for every command that connects to one.

Commands marked **creates** make a missing `.pgdb` with defaults, printing `creating <path>`. The others fail on a missing `.pgdb`.

#### `minipg <pgdb> [sql...]`, `shell <pgdb|url> [-d DB] [sql...] [-- psql args]`

Opens psql on the `.pgdb`, or runs each SQL argument as a statement. With a `postgres://` or `postgresql://` URL, runs the embedded psql against that server instead. Starts a background server if needed. **Creates.**

#### `init <pgdb> [--port N] [--user U] [--pg MAJOR]`

Creates a `.pgdb` and initializes its cluster, then prints `created <path> (Postgres <version>, database <name>)`. Refuses if the path exists. `--port` sets the preferred port (default: a free one), `--user` the superuser's name (default `POSTGRES_USER`, else `postgres`), and `--pg` the Postgres major (default: the embedded one). The password comes from `POSTGRES_PASSWORD` or is generated, and the default database from `POSTGRES_DB` or the file name. If initialization fails, the `.pgdb` is removed and the end of the log is printed.

#### `serve <pgdb> [-p PORT] [--listen ADDR] [--log FILE] [--trust] [--idle SECONDS] [-- postgres args]`

Runs the server in the foreground. See [Running a server explicitly](#6-running-a-server-explicitly).

#### `stop <pgdb>`

Asks the server for a fast shutdown and waits until the `.pgdb` is unlocked. Succeeds, with a note, if no server is running.

#### `status <pgdb>`

Prints the server's state and details. Exits 0 when a server is running and 3 when none is.

#### `url <pgdb> [-d DB]`

Prints a `postgres://user:password@host:port/database` URL, with the running server's port or the preferred one. Doesn't start a server. **Creates.**

#### `env <pgdb> [-d DB]`

Prints `DATABASE_URL`, `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, and `PGDATABASE` as shell-quoted `export` lines. Doesn't start a server. **Creates.**

#### `run <pgdb> [-d DB] -- CMD [args]`

Starts a server if needed, then runs CMD on the host with the same variables `env` prints, holding the server open until CMD exits. Exits with CMD's exit code, or 128 plus the signal number if CMD was killed by a signal. **Creates.**

#### `logs <pgdb> [-f]`

Prints the running server's recent log (a 4 MB window), following it with `-f` (or `--follow`). With no server running, prints the last server's log file.

#### `exec <pgdb> [-d DB] -- TOOL [args]`

Runs a Postgres tool from the image in its own machine, with the `PG*` variables set and your working directory as its own. Starts a background server if needed. Exits with the tool's exit code.

#### `dump <pgdb> [-d DB] [pg_dump args]`

Runs pg_dump on the database and writes the dump to stdout. Plain SQL unless the arguments say otherwise.

#### `restore <pgdb> [-d DB] [FILE]`

Restores a plain SQL or custom-format dump from FILE or stdin into the database, stopping at the first error. **Creates.**

#### `dbs <pgdb>`

Lists the databases (not templates) with their sizes. `*` marks the default.

#### `create <pgdb> NAME`

Creates a database.

#### `drop <pgdb> NAME`

Drops a database. Refuses to drop the default.

#### `default <pgdb> [NAME]`

Prints the default database, or makes NAME the default. NAME must exist.

#### `passwd <pgdb>`

Sets the superuser's password to `POSTGRES_PASSWORD`, or a newly generated one, and saves it.

#### `versions`

Lists the embedded Postgres version and any downloaded ones, with their digests, and where other majors come from.

#### `fetch MAJOR`

Downloads the newest `postgres:MAJOR-alpine` root for this host's architecture and prints its version and digest.

#### `prune`

Removes every downloaded root, keeping the embedded one. Roots come back on demand.

#### `--version`, `-v`; `--help`, `-h`

Print minipg's version, or the usage summary.

### 13.2 Environment variables

**minipg's own:**

| Variable | Effect |
|---|---|
| `MINIPG_IDLE` | Seconds a background server waits without clients before stopping. Default 60. |
| `MINIPG_OFFLINE` | When set, never download Postgres roots. |
| `MINIPG_REGISTRY` | Registry to download roots from: `host`, or `host/repository`. Default Docker Hub. |

**Read by `init`,** with the same meaning as in the Docker image:

| Variable | Effect |
|---|---|
| `POSTGRES_USER` | Superuser name. Default `postgres`. `--user` overrides it. |
| `POSTGRES_PASSWORD` | Superuser password. Default: generated. Also read by `passwd`. |
| `POSTGRES_DB` | Default database name. Default: the file name without `.pgdb`. |
| `POSTGRES_INITDB_ARGS` | Extra arguments for initdb, such as `--locale` or `--data-checksums`. Passing `--auth` or a locale option replaces minipg's own defaults for those. |
| `POSTGRES_INITDB_WALDIR` | A separate WAL directory, as a path inside the machine. |
| `TZ` | Time zone for the server, passed through on every start. |

**Set by `env`, `run`, and `exec`** for the programs they run: `DATABASE_URL` (`env` and `run` only), `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, and `PGDATABASE`.

**Network,** for root downloads: `HTTPS_PROXY`, `NO_PROXY`, and `SSL_CERT_FILE`.

**Paths,** on Linux: `XDG_RUNTIME_DIR`, `XDG_STATE_HOME`, and `XDG_CACHE_HOME`, as in [Files outside the .pgdb](#134-files-outside-the-pgdb). On macOS, `TMPDIR`. `HOME` must be set on both.

### 13.3 minipg.toml

`minipg.toml` is flat `key = value` lines, valid TOML. minipg ignores keys it doesn't know.

| Key | Example | Meaning | Edit by hand? |
|---|---|---|---|
| `format` | `1` | The `.pgdb` layout version | No |
| `pg.major` | `18` | Postgres major the cluster was created with; must match `pgdata/PG_VERSION` | No |
| `pg.variant` | `"alpine"` | libc family of the image, fixed for collation safety | No |
| `pg.arch` | `"amd64"` | Architecture the cluster was created on | No |
| `pg.digest` | `"sha256:..."` | Image digest of the root it was created with | No |
| `pg.last_opened` | `"18.4"` | Postgres version that last served it, for information | No |
| `user` | `"postgres"` | Superuser name | No; it must match the role in Postgres |
| `password` | `"..."` | Superuser password | Use `passwd`, which also changes it in Postgres |
| `database` | `"app"` | Default database | Yes, or use `default` |
| `port` | `54321` | Preferred port | Yes, with the server stopped |

### 13.4 Files outside the .pgdb

The `.pgdb` holds only data and settings. Runtime state, logs, and unpacked roots live in per-user directories:

| What | Linux | macOS |
|---|---|---|
| Runtime (`run.json`, control socket) | `$XDG_RUNTIME_DIR/minipg/<key>/` | `$TMPDIR/minipg-$UID/<key>/` |
| Logs | `~/.local/state/minipg/logs/<key>.log` | `~/Library/Logs/minipg/<key>.log` |
| Unpacked roots | `~/.cache/minipg/roots/<digest>/` | `~/Library/Caches/minipg/roots/<digest>/` |

`<key>` is a hash of the `.pgdb` directory's device and inode, so it follows the directory, not its name. On Linux, the runtime directory falls back to `~/.cache/minipg/run/` when `XDG_RUNTIME_DIR` isn't set, and `XDG_STATE_HOME` and `XDG_CACHE_HOME` replace `~/.local/state` and `~/.cache`. Runtime directories are mode 0700.

Everything here can be deleted while no server runs. Roots unpack again and logs start over.

### 13.5 Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Failure; the reason is on stderr |
| 2 | Usage error, such as a missing argument or a bad flag value |
| 3 | `status`: no server is running |
| Other | `run`, `exec`, `shell`, `dump`, and `restore` pass through the exit code of the program they ran |

---

## Appendix A: How it works

A short tour, for the curious. The README's "How it works" section and the source have the details.

- **h9.** hyper9 is a Plan 9 kernel that runs as a library inside minipg. Its Linux personality runs unmodified Linux binaries (here, Alpine's Postgres) on the host's hypervisor, answering their system calls itself. On x86_64 Linux without KVM, its native backend runs each guest process as a host process and intercepts its system calls instead.
- **The server process** ([src/server.zig](src/server.zig)) holds the lock, picks the port, writes `run.json`, serves the control socket, and runs Postgres in an h9 machine. The machine's root is the unpacked Alpine image, and its writable working directory is the `.pgdb`. The image's own `docker-entrypoint.sh` initializes a new cluster. A monitor thread logs in to see when Postgres is ready, then counts clients in `pg_stat_activity` for `status` and the idle timeout.
- **Shutdown** goes through a small supervisor shell in the machine, which sends SIGINT (a fast shutdown) to the postmaster alone.
- **The control socket** ([src/control.zig](src/control.zig)) is a unix socket with a one-line, versioned request protocol: `status`, `stop`, `logs`, and `clients`.
- **Clients** ([src/client.zig](src/client.zig)) find a running server or start one. **Tool machines** ([src/vm.zig](src/vm.zig)) run psql and the other tools over the same root.

## Appendix B: Building from source

Building needs [Zig 0.16](https://ziglang.org/download/), and `curl`, `jq`, `tar`, and `xz` to pull the root. hyper9 is a git submodule:

```sh
git submodule update --init
make build                       # pulls the root for this host's arch, builds ./minipg
make build OS=linux ARCH=arm64   # cross-compile (OS: linux, macos; ARCH: amd64, arm64)
make build PG_MAJOR=17           # embed another major
make test                        # unit tests
make e2e                         # end-to-end tests against ./minipg
```

macOS builds have to be made on a Mac, for the SDK's Hypervisor framework. See the README's [Building](README.md#building) section for more.

## Appendix C: Roadmap

Planned, but not in minipg yet:

- `upgrade <pgdb> --to MAJOR`, by dump and restore, and optionally `pg_upgrade`
- `init --image REF` for custom Postgres images, such as ones with extra extensions
- `psql` and `pg_dump` as symlinks to minipg (multicall)
- A macOS package declaration, so Finder shows a `.pgdb` as one file
- A single-file `.pgdb`
- Windows, once h9's backend for it matures
- Homebrew, apt, and other platform packages
