#!/bin/sh
# root.sh ARCH OUT: pull Docker Hub's postgres:17-alpine for linux/ARCH
# (amd64 or arm64), trim what postgres17-standalone doesn't use, and write
# the tree as an xz-compressed tarball to OUT. The binary embeds it and
# unpacks it into its cache dir on first run, where h9 serves it as the
# Linux root.
#
# Needs curl, jq, tar and xz; no Docker. The pull and whiteout handling
# follow hyper9's docs/containers/h9box. With ROOT_DIR set to an already
# unpacked image tree (such as `docker export` output), it skips the pull
# and trims a copy of that tree instead.
set -eu

ARCH=${1:?usage: root.sh ARCH OUT}
OUT=${2:?usage: root.sh ARCH OUT}
REF=${IMAGE:-library/postgres:17-alpine}
repo=${REF%:*} tag=${REF##*:}

die() { echo "root.sh: $*" >&2; exit 1; }
for c in curl jq tar xz; do command -v $c >/dev/null || die "needs $c"; done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
root=$work/root
mkdir -p "$root"

if [ -n "${ROOT_DIR:-}" ]; then
	(cd "$ROOT_DIR" && tar -cf - .) | (cd "$root" && tar -xpf -)
else
token=$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$repo:pull" | jq -r .token)
[ -n "$token" ] && [ "$token" != null ] || die "no registry token for $repo"
registry() {
	curl -fsSL -H "Authorization: Bearer $token" -H "Accept: ${2:-*/*}" \
		"https://registry-1.docker.io/v2/$repo/$1"
}

index='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json'
single='application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'
registry "manifests/$tag" "$index,$single" >"$work/m.json"
if jq -e 'has("manifests")' "$work/m.json" >/dev/null; then
	d=$(jq -r --arg a "$ARCH" \
		'[.manifests[] | select(.platform.os == "linux" and .platform.architecture == $a)][0].digest' "$work/m.json")
	[ "$d" != null ] || die "$REF has no linux/$ARCH image"
	registry "manifests/$d" "$single" >"$work/m.json"
fi

# Apply each layer in order, honoring whiteouts.
for layer in $(jq -r '.layers[].digest' "$work/m.json"); do
	echo "root.sh: $repo $layer" >&2
	l=$work/layer
	rm -rf "$l" && mkdir -p "$l"
	registry "blobs/$layer" | tar -xzf - -C "$l"
	find "$l" -name .wh..wh..opq | while IFS= read -r f; do
		dir=$root${f#"$l"}
		find "${dir%/*}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
		rm -f "$f"
	done
	find "$l" -name '.wh.*' | while IFS= read -r f; do
		r=${f#"$l"}
		rm -rf "$root${r%/*}/${r##*/.wh.}" "$f"
	done
	(cd "$l" && tar -cf - .) | (cd "$root" && tar -xpf -)
done
fi

# JIT (LLVM is most of the image), headers and docs aren't needed to serve.
# Without llvmjit.so, postgres runs with JIT unavailable.
rm -rf "$root"/usr/lib/libLLVM* \
	"$root"/usr/local/lib/postgresql/llvmjit* \
	"$root"/usr/local/lib/postgresql/bitcode \
	"$root"/usr/local/include \
	"$root"/usr/share/doc "$root"/usr/share/man

# Hard links become separate copies, since Zig's tar reader only takes
# files, directories and symlinks. Done in the tree rather than with GNU
# tar's --hard-dereference, which macOS's bsdtar lacks.
find "$root" -type f -links +1 | while IFS= read -r f; do
	cp -p "$f" "$f.copy" && mv -f "$f.copy" "$f"
done
mkdir -p "$(dirname "$OUT")"
# Separate steps, so a tar failure isn't hidden by the pipe.
(cd "$root" && tar -cf "$work/root.tar" .)
xz -9 -T0 -c "$work/root.tar" >"$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "root.sh: wrote $OUT ($(du -h "$OUT" | cut -f1))" >&2
