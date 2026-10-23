# postgres17-standalone

A single binary that runs PostgreSQL 17. It boots a 32-bit Linux VM in [v86](https://github.com/copy/v86) inside a headless browser. Postgres's data directory is a host folder shared with the VM over 9P, and the Postgres port is forwarded to the host through a virtual network.

You don't need Docker or a local Postgres install. You do need Chrome or Chromium, which [rod](https://github.com/go-rod/rod) uses to run the browser and will download for you automatically.

## Usage

```sh
POSTGRES_PASSWORD=secret postgres17-standalone [-p port] [-shell] <dataDir>
```

- `dataDir` (required): the host directory used as Postgres's data directory. It is created if it doesn't exist.
- `-p`: the host port to listen on, on all interfaces. Defaults to `5432`.
- `-shell`: start a shell in the VM instead of the Postgres entrypoint.

Environment variables:

| Variable            | Required | Default    |
|---------------------|----------|------------|
| `POSTGRES_PASSWORD` | yes (not with `-shell`) |            |
| `POSTGRES_USER`     | no       | `postgres` |
| `POSTGRES_DB`       | no       | `postgres` |

The VM console is attached to your terminal. Press Ctrl-D to exit.

```sh
psql -h localhost -U postgres
```

## Building

```sh
make assets   # build root.tar.br and bzImage via Docker
make dist     # cross-compile binaries into ./dist
```

## License

MIT
