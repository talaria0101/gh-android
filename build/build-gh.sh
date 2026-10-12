#!/usr/bin/env bash
# Cross-compile GitHub CLI for Android (Termux).
#
# Two toolchains are involved, and which one you need depends on the arch:
#
#   arm64   CGO_ENABLED=0. Go links it internally, so no C toolchain, no NDK and
#           no Bionic sysroot. This is the default and the only arch that builds
#           with nothing but a Go install.
#
#   arm     CGO_ENABLED=1 plus an Android NDK. Go cannot link android/arm
#           internally; it requires *external* cgo linking, and that means a C
#           compiler that targets Bionic. Point ANDROID_NDK_HOME at an unpacked
#           NDK and this script finds the right clang wrapper itself.
#
#   amd64   Same as arm, but only useful for x86_64 emulator images.
#
# Go's toolchain decides this, not this project. From
# internal/platform/supported.go, MustLinkExternal returns true for every android
# arch except arm64, so the others fail under CGO_ENABLED=0 with:
#
#     android/arm requires external (cgo) linking, but cgo is not enabled
#
# Usage:
#   ./build/build-gh.sh                        # arm64
#   ./build/build-gh.sh --arch arm             # 32-bit ARM, needs ANDROID_NDK_HOME
#   ./build/build-gh.sh --arch arm,amd64       # both
#   ANDROID_NDK_HOME=/path/to/ndk ./build/build-gh.sh --arch arm
#   GH_VERSION=v2.103.0 ./build/build-gh.sh
#   API=21 ./build/build-gh.sh --arch arm       # minimum Android API (default 21)

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="${DIST:-$REPO_ROOT/dist}"
# Make DIST absolute before anything changes directory. The cgo path builds in a
# throwaway module and writes with `-o "$out"`, so a relative DIST would resolve
# against that temporary directory and the binary would land somewhere the rest
# of this script never looks.
case "$DIST" in
/*) ;;
*) DIST="$PWD/$DIST" ;;
esac

GH_VERSION="${GH_VERSION:-v2.102.0}"
ARCHES="${ARCHES:-arm64}"

# API level handed to the NDK clang wrapper. 21 is Android 5.0 and the lowest
# Termux ever supported on 32-bit ARM; raise it if you need newer syscalls.
API="${API:-21}"

# -X main.version makes `gh --version` report the release we asked for instead of
# "dev". gh also reads buildDate/buildCommit; leave them out rather than invent.
LDFLAGS="-s -w -X main.version=${GH_VERSION#v}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'build-gh: %s\n' "$*" >&2; exit 1; }

usage() {
	cat <<'EOF'
Usage: build/build-gh.sh [options]

  --arch LIST    comma-separated arches: arm64, arm, amd64 (default: arm64)
                 arm64 needs no toolchain; arm and amd64 need ANDROID_NDK_HOME
  -h, --help     this text

Environment:
  GH_VERSION       gh release to build             (default: v2.102.0)
  ANDROID_NDK_HOME unpacked NDK, required for arm and amd64
  API              Android API level for arm/amd64 (default: 21)
  DIST             output directory                (default: ./dist)
EOF
}

# Parse options first, so --help works without a Go toolchain or an NDK present.
want_arches="$ARCHES"
while [ $# -gt 0 ]; do
	case "$1" in
	--arch)
		shift
		[ $# -gt 0 ] || die "--arch needs a value"
		want_arches="$1"
		;;
	--arch=*) want_arches="${1#--arch=}" ;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "unknown argument '$1' (try --help)" ;;
	esac
	shift
done

# Locate the NDK's cross clang for an arch, or explain what is missing.
# Layout: $ANDROID_NDK_HOME/toolchains/llvm/prebuilt/<host>/bin/<triple><api>-clang
ndk_cc() {
	local arch="$1"
	local triple

	case "$arch" in
	arm) triple=armv7a-linux-androideabi ;;
	amd64) triple=x86_64-linux-android ;;
	*) return 1 ;;
	esac

	if [ -z "${ANDROID_NDK_HOME:-}" ]; then
		die "$arch needs an Android NDK and ANDROID_NDK_HOME is not set.
     arm64 does not: drop $arch from --arch, or set ANDROID_NDK_HOME.
     NDK download: https://developer.android.com/ndk/downloads"
	fi
	[ -d "$ANDROID_NDK_HOME" ] || die "ANDROID_NDK_HOME=$ANDROID_NDK_HOME is not a directory"

	local prebuilt="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt"
	[ -d "$prebuilt" ] ||
		die "$ANDROID_NDK_HOME does not look like an NDK (no toolchains/llvm/prebuilt).
     Set ANDROID_NDK_HOME to the unpacked NDK directory itself, not the zip."

	# Find the host toolchain rather than assuming linux-x86_64.
	local host cc
	for host in "$prebuilt"/*; do
		[ -d "$host/bin" ] || continue
		cc="$host/bin/${triple}${API}-clang"
		if [ -x "$cc" ]; then
			printf '%s' "$cc"
			return 0
		fi
	done

	die "no ${triple}${API}-clang under $prebuilt/*/bin.
     Does this NDK ship the $arch toolchain? Try a different API level with API=."
}

# Refuse to ship something that is not what we think it is. A stale or
# mis-targeted binary means every device install is broken in a way that is
# painful to debug on a phone.
check_binary() {
	local out="$1" arch="$2"

	if ! command -v readelf >/dev/null 2>&1; then
		log "readelf not available, skipping structural checks on $out"
		return 0
	fi

	local header
	header="$(readelf -h "$out" 2>/dev/null || true)"

	case "$arch" in
	arm64) echo "$header" | grep -q 'AArch64' ||
		die "$out is not an AArch64 ELF" ;;
	arm) echo "$header" | grep -qE 'Machine:.*ARM' ||
		die "$out is not a 32-bit ARM ELF" ;;
	amd64) echo "$header" | grep -q 'Advanced Micro Devices X86-64' ||
		die "$out is not an x86-64 ELF" ;;
	esac

	echo "$header" | grep -q 'DYN' ||
		die "$out is not position-independent; Android requires a PIE"

	readelf -l "$out" 2>/dev/null | grep -q 'INTERP' ||
		die "$out has no PT_INTERP; Android needs the Bionic dynamic linker"

	# 64-bit arm64 binaries are pure Go and need nothing but the system linker.
	# The cgo-linked arches additionally need libc, which is expected.
	local needed
	needed="$(readelf -d "$out" 2>/dev/null |
		sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ')"
	case "$arch" in
	arm64)
		[ -z "${needed// /}" ] ||
			die "$out needs shared libraries ($needed); the arm64 build should be pure Go"
		;;
	arm | amd64)
		case "$needed" in
		*libc.so*) ;;
		*) die "$out does not list libc.so among its dependencies ($needed)" ;;
		esac
		;;
	esac

	log "checked $out: $(basename "$out"), ELF OK"
}

command -v go >/dev/null 2>&1 || die "go not found in PATH"

log "go $(go env GOVERSION) building gh ${GH_VERSION}"
mkdir -p "$DIST"

for arch in ${want_arches//,/ }; do
	out="$DIST/gh-$arch"

	case "$arch" in
	arm64)
		log "GOOS=android GOARCH=arm64 CGO_ENABLED=0 -> $out"

		# Two Go toolchain facts shape this command:
		#   * `go install` refuses to write a cross-compiled binary when GOBIN is
		#     set ("cannot install cross-compiled binaries when GOBIN is set"), so
		#     GOBIN must not be set here. It is unset explicitly rather than
		#     merely assumed absent, because a developer with GOBIN exported would
		#     otherwise hit exactly that error;
		#   * with GOBIN unset, Go writes to $GOPATH/bin/${GOOS}_${GOARCH}/gh.
		# `go build` is not an option: outside a module it rejects path@version.
		GOOS=android \
		GOARCH=arm64 \
		CGO_ENABLED=0 \
			env -u GOBIN go install -trimpath -ldflags "$LDFLAGS" \
				"github.com/cli/cli/v2/cmd/gh@${GH_VERSION}"

		staged="$(go env GOPATH)/bin/android_arm64/gh"
		;;
	arm | amd64)
		cc="$(ndk_cc "$arch")"
		case "$arch" in
		arm) goarm="${GOARM:-7}" ;;
		amd64) goarm="" ;;
		esac
		log "GOOS=android GOARCH=$arch CGO_ENABLED=1 CC=$cc API=$API"

		# cgo is mandatory here, so `go install` is not usable: a cross-compiled
		# cgo build will not take an output path from outside a module, and
		# path@version is only accepted by install. Build in a throwaway module
		# instead, which supports both.
		work="$DIST/.build-$arch"
		rm -rf "$work"
		mkdir -p "$work"
		if ! (
			cd "$work"
			go mod init gh-android-build >/dev/null 2>&1 || true
			GOFLAGS=-mod=mod go get "github.com/cli/cli/v2/cmd/gh@${GH_VERSION}" >/dev/null
			GOOS=android \
			GOARCH="$arch" \
			GOARM="$goarm" \
			CGO_ENABLED=1 \
			CC="$cc" \
			CXX="${cc}++" \
				go build -trimpath -ldflags "$LDFLAGS" \
					-o "$out" github.com/cli/cli/v2/cmd/gh
		); then
			rm -rf "$work"
			die "cgo build for $arch failed"
		fi
		rm -rf "$work"
		staged="$out"
		;;
	*)
		die "unknown arch '$arch' (use arm64, arm or amd64)"
		;;
	esac

	[ -f "$staged" ] || die "build produced no binary at $staged"
	if [ "$staged" != "$out" ]; then
		mv "$staged" "$out"
		# Only the arm64 path stages outside $DIST, and this clears the empty
		# directory Go created. On the cgo path staged is $out, and there is
		# nothing of ours to remove.
		rmdir "$(dirname "$staged")" 2>/dev/null || true
	fi
	chmod 0755 "$out"

	check_binary "$out" "$arch"
	log "built $arch: $(du -h --apparent-size "$out" | cut -f1) apparent, $(du -h "$out" | cut -f1) on disk"
done

# Ship a manifest so a device can verify what it installed.
#
# Regenerate it from every binary actually present in $DIST, not just the ones
# this run built. Rebuilding a single arch must not drop the others from the
# manifest, or a device installing one of them would find no entry and silently
# skip its checksum check.
present=""
for candidate in arm64 arm amd64; do
	[ -f "$DIST/gh-$candidate" ] && present="$present gh-$candidate"
done
if [ -n "$present" ]; then
	# shellcheck disable=SC2086
	(cd "$DIST" && sha256sum $present >SHA256SUMS)
	log "wrote $DIST/SHA256SUMS"
	cat "$DIST/SHA256SUMS"
fi
