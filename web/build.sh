#!/bin/sh
# Builds the web demo into OUT (default .zig-out/web): h9's browser host,
# the page, and minipg.h9a.gz, a trimmed 386 Postgres root with a Linux
# build of minipg and a template cluster for fast init.
#
# Needs assets/root-386.tar.xz (make root ARCH=386), zig, npm (for
# xterm.js), and Node 24 or later as NODE (h9-node makes the template
# cluster under h9).
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-.zig-out/web}
NODE=${NODE:-node}
H9=${H9:-deps/hyper9}
work=.zig-cache/web
rm -rf "$work" && mkdir -p "$work/full" "$OUT"
root=$(pwd)

echo "web: h9's browser host" >&2
(cd "$H9" && zig build web)

echo "web: minipg for 386 Linux" >&2
zig build -Dhost=linux -Dtarget=x86-linux-musl -Doptimize=ReleaseSmall -Dversion="${VERSION:-dev}" -p "$work/minipg"

echo "web: the template cluster" >&2
tar -xJf assets/root-386.tar.xz -C "$work/full"
cp "$work/minipg/bin/minipg" "$work/full/usr/local/bin/minipg"
mkdir -p "$work/tpl"
# 1 MB WAL segments rather than 16: the demo's clusters are small, and
# every byte of the template is downloaded.
"$NODE" --disable-warning=ExperimentalWarning "$H9/zig-out/web/h9-node" --arch 386 \
	--root "$work/full" --writable "$work/tpl" --cwd "$work/tpl" --memory 1G \
	--env HOME=/root --env PATH=/usr/local/bin:/usr/bin:/bin \
	--env POSTGRES_DB=postgres --env POSTGRES_PASSWORD=template --env POSTGRES_INITDB_ARGS=--wal-segsize=1 \
	-- /usr/local/bin/minipg init /mnt/term/cwd/t.pgdb
rm -f "$work/tpl/t.pgdb/pgdata/postmaster.opts"

echo "web: the root" >&2
sh web/trim.sh "$work/full" "$work/root"
cp "$work/minipg/bin/minipg" "$work/root/usr/local/bin/minipg"
mkdir -p "$work/root/usr/local/share/minipg"
cp -R "$work/tpl/t.pgdb/pgdata" "$work/root/usr/local/share/minipg/template"
cp web/profile.sh "$work/root/etc/profile.d/minipg.sh"
# Every top-level entry whole, and the mount points h9 needs, empty.
{ (cd "$work/root" && ls -A); printf '%s\n' 9/ mnt/term/cwd/; } >"$work/list"
zig run -OReleaseSafe "$H9/tools/webroot.zig" -- "$work/root" "$work/list" "$work/minipg.h9a"
gzip -9 -c "$work/minipg.h9a" >"$OUT/minipg.h9a.gz"

for f in h9-web.js worker.js wasi-mem.js h9.wasm v86.wasm LICENSE.v86; do
	cp "$H9/zig-out/web/$f" "$OUT/$f"
done
cp web/index.html "$OUT/index.html"
# xterm.js, the page's terminal, from npm.
(cd "$work" && npm pack --silent @xterm/xterm@5.5.0 @xterm/addon-fit@0.10.0 >/dev/null)
mkdir -p "$work/xterm" "$OUT/xterm"
for t in "$work"/*.tgz; do tar -xzf "$t" -C "$work/xterm"; mv "$work/xterm/package" "$work/xterm/$(basename "$t" .tgz)"; done
cp "$work"/xterm/xterm-xterm-*/lib/xterm.js "$work"/xterm/xterm-xterm-*/css/xterm.css \
	"$work"/xterm/xterm-addon-fit-*/lib/addon-fit.js "$work"/xterm/xterm-xterm-*/LICENSE "$OUT/xterm/"
echo "web: wrote $OUT ($(du -h "$OUT/minipg.h9a.gz" | cut -f1) root)" >&2
