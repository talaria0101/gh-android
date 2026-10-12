#!/usr/bin/env bash
# Run the Android gh binary, without an Android phone.
#
# dist/gh-arm64 is a PIE that needs /system/bin/linker64, so it cannot exec
# directly on this host, and no user-mode emulator here can supply Bionic's
# linker. Two things follow, and both are run below rather than assumed:
#
#   * the shipped binary is checked structurally: right arch, has a PT_INTERP,
#     no unexpected DT_NEEDED, and its embedded Go version matches the pin;
#   * the same source built for linux/arm64 is executed under
#     qemu-aarch64-static, which does prove the gh code, the ldflags version
#     pin and the config-path logic work on aarch64.
#
# What that does NOT prove, and it is worth being blunt about: that Go's
# android/arm64 runtime initialises correctly on a real Bionic device, because
# linux/arm64 links statically against glibc instead. Confirming the shipped
# artifact itself needs `gh --version` to be run on a phone.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"

# Every binary the build produces, checked structurally. arm64 is pure Go and
# needs nothing but the system linker; arm and amd64 are cgo-linked and pull in
# Bionic's libc.
#
#   arch    readelf Machine pattern    interpreter        libc.so expected
#   arm64   AArch64                   /system/bin/linker64  no
#   arm     ARM (32-bit)              /system/bin/linker     yes
#   amd64   x86-64                    /system/bin/linker64  yes
BIN="$ROOT/dist/gh-arm64"

SCRATCH="${GHM_TEST_SCRATCH:-$ROOT/.scratch}"
# `chmod -R` first: Go writes its module cache read-only, so a plain rm -rf
# fails on those files and leaves a tree that breaks every later run.
cleanup() {
	chmod -R u+w "$SCRATCH" 2>/dev/null || true
	rm -rf "$SCRATCH"
}
cleanup
mkdir -p "$SCRATCH"
trap cleanup EXIT

# Keep the Go module cache out of $SCRATCH for the same reason: read-only module
# files cannot be removed by the trap above. Default to the user's real cache so
# nothing lands inside the repo, and fall back to a scratch dir only if the
# environment insists on one.
if [ -z "${GOMODCACHE:-}" ] && [ -z "${HOME:-}" ]; then
	export GOMODCACHE="$SCRATCH/gomodcache"
fi
: "${GOMODCACHE:=${HOME:-$SCRATCH}/go/pkg/mod}"
mkdir -p "$GOMODCACHE"

passed=0
failed=0
skipped=0
ok() {
	printf '  ok    %s\n' "$1"
	passed=$((passed + 1))
}
no() {
	printf '  FAIL  %s\n' "$1"
	shift
	[ $# -gt 0 ] && printf '        %s\n' "$@"
	failed=$((failed + 1))
}
check_eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want: $2" "got:  $3"; fi
}

# Nothing here needs a pre-built binary, but the ELF checks do. dist/ is
# gitignored, because the binaries are CI release assets, so a fresh clone has
# none until someone builds. Exiting 1 was wrong: on CI this suite runs in the
# verify job, before the build job, and would fail every push for a missing
# artifact rather than for a real defect. The execution checks further down build
# their own linux/ siblings and still run either way.
if [ ! -f "$BIN" ]; then
	printf '  SKIP  no built binaries in dist/, so the ELF checks are skipped.\n'
	printf '        Build one with ./build/build-gh.sh, or --arch arm for 32-bit.\n'
else
	# --- structural checks on every shipped binary --------------------------

	# check_arch ARCH MACHINE_REGEX INTERCEPT [expect_libc]
	check_arch() {
	local name="$1" machine_re="$2" interp="$3" expect_libc="${4:-no}"
	local bin="$ROOT/dist/gh-$name"

	if [ ! -f "$bin" ]; then
		printf '  SKIP  dist/gh-%s not built (arm64 only needs Go; %s needs ANDROID_NDK_HOME)\n' \
			"$name" "$name"
		skipped=$((skipped + 1))
		return 0
	fi

	if ! readelf -h "$bin" 2>/dev/null | grep -qE "$machine_re"; then
		no "dist/gh-$name is the right machine type" \
			"got: $(readelf -h "$bin" 2>/dev/null | sed -n 's/.*Machine: *//p')"
		return 0
	fi
	ok "dist/gh-$name is the right machine type"

	if readelf -h "$bin" 2>/dev/null | grep -q 'DYN'; then
		ok "dist/gh-$name is position-independent, as Android requires"
	else
		no "dist/gh-$name is a PIE" "ELF type is not DYN"
	fi

	local got_interp
	got_interp="$(readelf -l "$bin" 2>/dev/null | grep -o '/system/bin/linker[0-9]*' | head -1)"
	check_eq "dist/gh-$name asks for $interp" "$interp" "$got_interp"

	local needed
	needed="$(readelf -d "$bin" 2>/dev/null |
		sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ')"
	case "$expect_libc" in
	yes)
		case "$needed" in
		*libc.so*)
			ok "dist/gh-$name links Bionic's libc" ;;
		*)
			no "dist/gh-$name links Bionic's libc" "needed: '$needed'" ;;
		esac
		# A cgo build must actually contain cgo support, or the libc link is a
		# leftover from a flag that was set but did not take effect.
		if readelf -s "$bin" 2>/dev/null | grep -q '_cgo_'; then
			ok "dist/gh-$name is cgo-linked, as its arch requires"
		else
			no "dist/gh-$name is cgo-linked" "no _cgo_ symbols found"
		fi
		;;
	no)
		check_eq "dist/gh-$name needs no shared libraries beyond the system linker" \
			"" "$needed"
		if readelf -s "$bin" 2>/dev/null | grep -q '_cgo_'; then
			no "dist/gh-$name is pure Go" "found _cgo_ symbols"
		else
			ok "dist/gh-$name is pure Go (no cgo symbols)"
		fi
		;;
	esac
}

	check_arch arm64 'AArch64' '/system/bin/linker64' no
	check_arch arm 'ARM' '/system/bin/linker' yes
	check_arch amd64 'X86-64' '/system/bin/linker64' yes

	# 32-bit must actually be 32-bit. `Machine: ARM` also matches a 64-bit ARM
	# string in some readelf versions, so check the ELF class directly.
	if [ -f "$ROOT/dist/gh-arm" ]; then
		class="$(readelf -h "$ROOT/dist/gh-arm" 2>/dev/null | sed -n 's/.*Class: *//p')"
		check_eq "dist/gh-arm is ELF32" "ELF32" "$class"
	fi
fi

# --- execute an aarch64 build of the same source ---------------------------

QEMU="$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)"
if [ -z "$QEMU" ]; then
	printf '  SKIP  qemu-aarch64 not available, cannot execute an aarch64 build\n'
	printf '\n%d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
	[ "$failed" -eq 0 ]
	exit $?
fi

printf '  ..    building linux/arm64 sibling for execution (needs module cache)\n'

# Derive the version from the build script so the two cannot drift. Hardcoding
# it here made a GH_VERSION bump fail this test for the wrong reason.
pin="$(sed -n 's/^GH_VERSION="\${GH_VERSION:-\(.*\)}"/\1/p' "$ROOT/build/build-gh.sh")"
if [ -z "$pin" ]; then
	printf '  FAIL  could not read GH_VERSION from build/build-gh.sh\n'
	exit 1
fi

(
	cd "$SCRATCH"
	go mod init runner >/dev/null 2>&1 || true
	GOFLAGS=-mod=mod go get github.com/cli/cli/v2/cmd/gh@"$pin" >/dev/null 2>&1
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath \
		-ldflags "-s -w -X main.version=${pin#v}" \
		-o "$SCRATCH/gh-linux-arm64" github.com/cli/cli/v2/cmd/gh
) >"$SCRATCH/build.log" 2>&1 || {
	printf '  FAIL  could not build linux/arm64 sibling\n'
	tail -5 "$SCRATCH/build.log"
	failed=$((failed + 1))
	printf '\n%d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
	exit 1
}

# The build strips the leading v for the ldflags value, because gh's own version
# string has no v on the first line. Compare against that same form.
want_version="${pin#v}"
got_version="$("$QEMU" "$SCRATCH/gh-linux-arm64" --version 2>&1 | head -1)"
check_eq "aarch64 gh reports the pinned version" "gh version $want_version" "$got_version"

# gh resolves its config through $HOME (or $XDG_CONFIG_HOME). With cgo disabled on
# android, os/user returns a dummy record, so prove gh does not depend on a
# passwd database the way some other Go programs do.
export HOME="$SCRATCH/home"
mkdir -p "$HOME"
unset XDG_CONFIG_HOME GH_TOKEN GH_HOST GITHUB_TOKEN

out="$("$QEMU" "$SCRATCH/gh-linux-arm64" config get git_protocol 2>&1)"
check_eq "gh reads a config default with no passwd entry" "https" "$out"

"$QEMU" "$SCRATCH/gh-linux-arm64" config set git_protocol ssh >/dev/null 2>&1
out="$("$QEMU" "$SCRATCH/gh-linux-arm64" config get git_protocol 2>&1)"
check_eq "gh writes and reads back its config under \$HOME" "ssh" "$out"

if [ -f "$HOME/.config/gh/config.yml" ]; then
	ok "config landed at \$HOME/.config/gh/config.yml"
else
	no "config path" "expected $HOME/.config/gh/config.yml"
fi

# A subcommand's help must work: this is the path a user hits when a phone
# keyboard makes an interactive prompt awkward.
if "$QEMU" "$SCRATCH/gh-linux-arm64" pr create --help >/dev/null 2>&1; then
	ok "gh pr create --help works on aarch64"
else
	no "gh pr create --help" "non-zero exit"
fi

# --- execute a 32-bit ARM build of the same source ------------------------
#
# arm is the arch people ask for when their device or Termux is 32-bit, so run
# the same checks under qemu-arm rather than trusting that aarch64 covers it.
# A 32-bit build differs in GOARM, which selects the ARM instruction set and
# floating-point ABI, so this is not redundant with the aarch64 case.

QEMU_ARM="$(command -v qemu-arm-static || command -v qemu-arm || true)"
if [ -z "$QEMU_ARM" ]; then
	printf '  SKIP  qemu-arm not available, cannot execute a 32-bit ARM build\n'
	printf '\n%d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
	[ "$failed" -eq 0 ]
	exit $?
fi

printf '  ..    building linux/arm sibling for execution\n'
armlog="$SCRATCH/build-arm.log"
if ! (
	cd "$SCRATCH"
	GOFLAGS=-mod=mod go get "github.com/cli/cli/v2/cmd/gh@$pin" >/dev/null 2>&1
	GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 go build -trimpath \
		-ldflags "-s -w -X main.version=${pin#v}" \
		-o "$SCRATCH/gh-linux-arm" github.com/cli/cli/v2/cmd/gh
) >"$armlog" 2>&1; then
	no "could not build linux/arm sibling" "$(tail -3 "$armlog")"
else
	got="$("$QEMU_ARM" "$SCRATCH/gh-linux-arm" --version 2>&1 | head -1)"
	check_eq "32-bit ARM gh reports the pinned version" "gh version $want_version" "$got"

	class="$(readelf -h "$SCRATCH/gh-linux-arm" 2>/dev/null | sed -n 's/.*Class: *//p')"
	check_eq "the executed binary really is 32-bit" "ELF32" "$class"

	# A fresh $HOME: the aarch64 case above set git_protocol=ssh, and sharing
	# $HOME would make this check read that back instead of gh's own default.
	export HOME="$SCRATCH/home-arm"
	rm -rf "$HOME"
	mkdir -p "$HOME"
	unset XDG_CONFIG_HOME GH_TOKEN GH_HOST GITHUB_TOKEN

	# gh must resolve its config through $HOME on 32-bit too. With cgo disabled
	# on Android, os/user returns a dummy record, so gh must not be leaning on a
	# passwd database; this is the same check the aarch64 build gets.
	out="$("$QEMU_ARM" "$SCRATCH/gh-linux-arm" config get git_protocol 2>&1)"
	check_eq "32-bit ARM gh reads a config default with no passwd entry" "https" "$out"

	"$QEMU_ARM" "$SCRATCH/gh-linux-arm" config set git_protocol ssh >/dev/null 2>&1
	out="$("$QEMU_ARM" "$SCRATCH/gh-linux-arm" config get git_protocol 2>&1)"
	check_eq "32-bit ARM gh writes and reads back its config" "ssh" "$out"

	if "$QEMU_ARM" "$SCRATCH/gh-linux-arm" pr create --help >/dev/null 2>&1; then
		ok "gh pr create --help works on 32-bit ARM"
	else
		no "gh pr create --help on 32-bit ARM" "non-zero exit"
	fi
fi

printf '\n%d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
[ "$failed" -eq 0 ]
