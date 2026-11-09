#!/bin/sh
# Pares a 386 postgres:alpine root tree down to what the web demo runs:
# busybox, bash, docker-entrypoint.sh, Postgres, the client tools minipg
# runs, and the shared libraries they need.
#   web/trim.sh SRC DST
set -eu
src=$(cd "$1" && pwd) dst=$2
rm -rf "$dst" && mkdir -p "$dst"
keep() { (cd "$src" && tar -cf - "$@") | (cd "$dst" && tar -xpf -); }

keep bin sbin etc lib var root tmp usr/bin usr/sbin usr/share/zoneinfo \
	usr/local/share/postgresql docker-entrypoint-initdb.d
for t in postgres psql initdb pg_ctl pg_isready pg_dump pg_dumpall pg_restore \
	createdb dropdb gosu docker-entrypoint.sh docker-ensure-initdb.sh; do
	keep usr/local/bin/$t
done
# Postgres's own modules, but not pgxs (the extension build kit).
keep usr/local/lib/postgresql
rm -rf "$dst"/usr/local/lib/postgresql/pgxs
mkdir -p "$dst"/dev "$dst"/proc "$dst"/sys "$dst"/run "$dst"/usr/lib "$dst"/usr/local/lib

# Shared libraries: the closure of what every kept ELF file needs.
need() { readelf -d "$1" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'; }
find_lib() {
	for d in lib usr/lib usr/local/lib; do
		[ -e "$src/$d/$1" ] && { echo "$d/$1"; return; }
	done
}
todo=$(find "$dst" -type f \( -perm -u+x -o -name '*.so*' \))
seen=" "
while [ -n "$todo" ]; do
	next=
	for f in $todo; do
		for n in $(need "$f"); do
			case "$seen" in *" $n "*) continue ;; esac
			seen="$seen$n "
			p=$(find_lib "$n") || true
			[ -n "$p" ] || continue
			# The soname is usually a symlink to the versioned file.
			real=$(cd "$src" && readlink -f "$p" | sed "s|^$src/||")
			keep "$p"
			[ "$real" = "$p" ] || keep "${real#/}"
			next="$next $dst/${real#/}"
		done
	done
	todo=$next
done
# ICU's 30 MB of locale data: the demo's clusters use the builtin
# provider, and come from a template made with the full root.
rm -rf "$dst"/usr/share/icu

# h9's root archive has no symlinks: it would copy each link's target.
# A library's soname becomes the file itself, and the versioned files
# nothing names go. Busybox's applets come back with `busybox --install`
# at login, and /var/run, where Postgres's default socket goes, becomes a
# directory.
for l in $(find "$dst" -type l); do
	case "$l" in
	*.so.*)
		t=$(readlink "$l")
		case "$t" in /*) t=$dst$t ;; *) t=$(dirname "$l")/$t ;; esac
		rm "$l"
		[ -f "$t" ] && cp -p "$t" "$l"
		;;
	*) rm "$l" ;;
	esac
done
for d in usr/lib usr/local/lib; do
	for f in "$dst/$d"/*.so.*; do
		[ -f "$f" ] || continue
		case "$seen" in *" ${f##*/} "*) ;; *) rm "$f" ;; esac
	done
done
mkdir -p "$dst"/var/run/postgresql && chmod 3777 "$dst"/var/run/postgresql
du -sh "$dst" >&2
