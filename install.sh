#!/usr/bin/env bash
# Install gh (and ghm) into a Termux prefix from a checkout of this repo.
#
# Run this on the phone, not on a desktop. It needs the binary for the phone's
# own architecture, which means either building here with Termux's clang
# (see README) or fetching dist/gh-arm64 built elsewhere.
#
#   bash install.sh
#
# Options:
#   --no-keys    skip installing termux/termux.properties
#   --force      overwrite existing files without asking
#   --uninstall  remove what this script installed

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Termux always exports PREFIX. Remember whether it was set before any default,
# because that is the only reliable signal that this is a phone shell and not a
# desktop one where the user ran the script by mistake.
PREFIX_WAS_SET=0
[ -n "${PREFIX:-}" ] && PREFIX_WAS_SET=1

BIN_DIR="${PREFIX:+$PREFIX/bin}"
BIN_DIR="${BIN_DIR:-/data/data/com.termux/files/usr/bin}"
TERMUX_HOME="${TERMUX_HOME:-$HOME}"

usage() {
	cat <<'EOF'
Install gh and ghm into a Termux prefix.

Usage:
  bash install.sh [--no-keys] [--force] [--uninstall]

  --no-keys    do not install ~/.tmux.conf or
               ~/.termux/termux.properties (gh and ghm still install)
  --force      overwrite existing files instead of leaving them alone
  --uninstall  remove the gh and ghm this script installed
EOF
}

# Defined before the option loop below calls it. Bash reads and runs a script a
# line at a time, so a function used at line 40 and defined at line 55 is not
# defined yet when it is called.
log() { printf '==> %s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

want_keys=1
force=0
uninstall=0

for arg in "$@"; do
	case "$arg" in
	--no-keys) want_keys=0 ;;
	--force) force=1 ;;
	--uninstall) uninstall=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	*) printf 'install: unknown option %s\n' "$arg" >&2; exit 1 ;;
	esac
done

# --- uninstall -------------------------------------------------------------

if [ "$uninstall" -eq 1 ]; then
	# Uninstall removes exactly what this script recorded installing. Without that
	# record the only two candidates for $PREFIX/bin/gh are this project's binary
	# and one that `pkg install gh` put there, and deleting the second silently
	# would leave the package manager disagreeing with the filesystem.
	stamp="$TERMUX_HOME/.gh-android-installed"
	log "removing gh and ghm from $BIN_DIR"
	failed=0

	if [ ! -f "$stamp" ]; then
		die "no record of a previous install at $stamp.
     Not guessing: \$PREFIX/bin/gh may have come from 'pkg install gh'.
     If you are sure it is ours, remove it by hand:
         rm -f $BIN_DIR/gh $BIN_DIR/ghm"
	fi

	while IFS= read -r target; do
		[ -n "$target" ] || continue
		# Only ever remove a path this script recorded, and only under BIN_DIR.
		case "$target" in
		"$BIN_DIR"/*) ;;
		*)
			printf 'install: ignoring %s, which is not under %s\n' "$target" "$BIN_DIR" >&2
			continue
			;;
		esac
		# -e is false for a dangling symlink, so test -e || -L: otherwise a
		# symlink left pointing at a removed file would survive and the record
		# would still be deleted.
		if [ -e "$target" ] || [ -L "$target" ]; then
			if rm -v "$target"; then
				:
			else
				# Do not claim success here. A silent failure means the user
				# believes gh is gone and finds out later, from a shell prompt
				# that still resolves gh.
				printf 'install: could not remove %s\n' "$target" >&2
				failed=1
			fi
		fi
	done <"$stamp"

	# Keep the record when anything went wrong. Deleting it on a partial
	# uninstall would leave nothing to retry with, and the retry would then
	# refuse for want of a record.
	if [ "$failed" -eq 0 ]; then
		rm -f "$stamp" || failed=1
	else
		printf 'install: left %s in place so you can retry\n' "$stamp" >&2
	fi

	[ "$failed" -eq 0 ] || die "uninstall incomplete; see the errors above"
	log "left ~/.termux/termux.properties and ~/.tmux.conf alone; remove them by hand if you want them gone"
	exit 0
fi

# --- environment -----------------------------------------------------------

# Refuse to run on a desktop by accident. Termux sets PREFIX; a shell that has
# not is either not Termux or has a broken environment, and installing an
# Android binary into /usr/local/bin on a laptop helps nobody.
if [ "$PREFIX_WAS_SET" -eq 0 ]; then
	die "PREFIX is not set, so this does not look like Termux.
     On a phone, run this from Termux (it sets PREFIX automatically).
     To override deliberately: PREFIX=/your/prefix bash install.sh"
fi

[ -d "$BIN_DIR" ] || die "$BIN_DIR does not exist. Is this really a Termux prefix?"

ARCH="$(uname -m)"
log "architecture: $ARCH"

# Used in the "not built yet" message below, so `gh release download` knows which
# repository to fetch from. Derive it from git so the message stays correct after
# a fork or a rename, and fall back to the well-known name.
#
# `|| true` matters: with `set -e` and `pipefail`, a plain assignment whose
# command substitution fails aborts the script. `git config --get` exits non-zero
# when there is no remote, or when this is not a git checkout at all, and that
# must not stop an install.
REPO_SLUG="$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null |
	sed -e 's#.*github.com[:/]##' -e 's#\.git$##' || true)"
REPO_SLUG="${REPO_SLUG:-<owner>/gh-android}"
case "$ARCH" in
aarch64 | arm64) want_arch=arm64 ;;
armv7l | armv8l | armv6l | arm) want_arch=arm ;;
i386 | i686) want_arch=386 ;;
x86_64 | amd64) want_arch=amd64 ;;
*)
	die "unsupported architecture '$ARCH'.
     Supported: arm64, arm (32-bit), amd64.
     Each needs its own binary in dist/; see the README for which ones
     build without a toolchain."
	;;
esac

# Give 32-bit x86 its own message. It is Android's last CPU that predates every
# Termux release, so there is no build for it and `pkg install gh` is the advice
# rather than "unsupported architecture".
if [ "$want_arch" = "386" ]; then
	die "no dist/gh-386 is built.
     32-bit x86 Android is not a target here: every Android release that ran it
     predates the versions Termux supports. Use Termux's own package:
         pkg install gh"
fi

# --- packages gh needs -----------------------------------------------------

# gh shells out to git for anything repo-related, and termux-wake-lock comes
# from termux-tools. Missing packages are reported rather than silently skipped,
# because gh without git fails later and more confusingly.
missing=()
for pkg_cmd in "git:git" "tmux:tmux"; do
	name="${pkg_cmd%%:*}"
	command -v "$name" >/dev/null 2>&1 || missing+=("$name")
done

if [ ${#missing[@]} -gt 0 ]; then
	log "missing: ${missing[*]}"
	if command -v pkg >/dev/null 2>&1; then
		printf 'install them with: pkg install %s\n' "${missing[*]}"
	else
		printf 'install them with Termux before continuing\n'
	fi
	die "cannot continue until these are installed"
fi

# --- gh binary -------------------------------------------------------------

SRC="$REPO_ROOT/dist/gh-$want_arch"
if [ ! -f "$SRC" ]; then
	# Binaries are not committed: CI builds them and attaches them to the tagged
	# release. So downloading is the normal path, and building is the fallback
	# for someone who wants a specific version. Give the exact download first,
	# naming the file for this arch so the wrong one cannot be fetched by mistake.
	cat >&2 <<EOF
install: $SRC not found for this device's architecture ($ARCH).

The binaries are not in the repository; CI attaches them to the release.
Download the one for this device and put it in place:

    gh-$want_arch  ->  dist/gh-$want_arch

From the Releases page of this repository, or:

    gh release download --repo $REPO_SLUG --pattern gh-$want_arch \\
        --dir dist --clobber
    gh release download --repo $REPO_SLUG --pattern SHA256SUMS \\
        --dir dist --clobber

Then re-run: bash install.sh

To build it yourself instead (needs an Android NDK for $want_arch):

    ANDROID_NDK_HOME=/path/to/ndk ./build/build-gh.sh --arch $want_arch

arm64 needs no NDK: ./build/build-gh.sh
EOF
	exit 1
fi

# Check only this arch's line. sha256sum -c verifies every file named in the
# manifest, so a repo that ships arm64 and arm would fail to install on arm
# merely because an amd64 binary in the same directory was rebuilt.
if [ -f "$REPO_ROOT/dist/SHA256SUMS" ] && grep -q " gh-$want_arch\$" "$REPO_ROOT/dist/SHA256SUMS"; then
	if (cd "$REPO_ROOT/dist" && sha256sum -c --status "SHA256SUMS" 2>/dev/null) ||
		(cd "$REPO_ROOT/dist" && grep " gh-$want_arch\$" SHA256SUMS | sha256sum -c --status); then
		log "checksum OK for gh-$want_arch"
	else
		die "checksum mismatch for gh-$want_arch; refusing to install.
     Rebuild with ./build/build-gh.sh, or delete dist/SHA256SUMS to skip this check."
	fi
elif [ -f "$REPO_ROOT/dist/SHA256SUMS" ]; then
	log "no entry for gh-$want_arch in dist/SHA256SUMS, skipping the checksum"
fi

if [ -e "$BIN_DIR/gh" ] && [ "$force" -ne 1 ]; then
	die "$BIN_DIR/gh already exists. Re-run with --force to replace it."
fi

log "installing gh -> $BIN_DIR/gh"
install -m 0755 "$SRC" "$BIN_DIR/gh"

# Prove the binary runs on this device before writing anything else. A binary
# that cannot exec is worse than no binary, because gh's absence is obvious and
# a broken one is not.
#
# Call it by full path. A bare `gh` would resolve through PATH and may be a
# different gh entirely: Termux ships its own gh package, so a user who ran
# `pkg install gh` first would have install.sh "verify" that one and never
# notice the binary it just installed is unusable.
if ! "$BIN_DIR/gh" --version >/dev/null 2>&1; then
	die "installed gh did not run on this device.
     $("$BIN_DIR/gh" --version 2>&1 | head -3)"
fi
log "gh works: $("$BIN_DIR/gh" --version | head -1)"

# --- ghm wrapper -----------------------------------------------------------

log "installing ghm -> $BIN_DIR/ghm"
install -m 0755 "$REPO_ROOT/bin/ghm" "$BIN_DIR/ghm"

# Record what this script put in place, so --uninstall removes exactly these
# paths and never a gh that came from `pkg install gh`.
printf '%s\n%s\n' "$BIN_DIR/gh" "$BIN_DIR/ghm" >"$TERMUX_HOME/.gh-android-installed"
log "recorded installed paths in $TERMUX_HOME/.gh-android-installed"

# --- config files ----------------------------------------------------------
#
# Both are inside the want_keys guard. --no-keys is documented as skipping
# "the config files", and ~/.tmux.conf used to be written anyway.

if [ "$want_keys" -eq 1 ]; then
	# Like the properties file, never replace a config the user already has. A
	# ~/.tmux.conf is personal, and losing one on a phone where editing it is
	# painful is a bad trade for a few convenience defaults.
	tmux_conf="$TERMUX_HOME/.tmux.conf"
	if [ -e "$tmux_conf" ] && [ "$force" -ne 1 ]; then
		install -m 0644 "$REPO_ROOT/termux/tmux.conf" "$tmux_conf.new"
		log "existing $tmux_conf left alone; new config written to $tmux_conf.new"
		printf '    to use it: mv %q %q\n' "$tmux_conf.new" "$tmux_conf"
	elif [ -w "$TERMUX_HOME" ] || [ -e "$tmux_conf" ]; then
		install -m 0644 "$REPO_ROOT/termux/tmux.conf" "$tmux_conf"
		log "installed $tmux_conf"
		# A running tmux server will not pick this up. ghm kill only ends one
		# session and, with exit-empty off, leaves the server alive, so it is not
		# a way to reload the config.
		printf '    tmux reads this when its server starts; to apply it now:\n'
		printf '        tmux source-file %q\n' "$tmux_conf"
	else
		log "could not write $tmux_conf; copy termux/tmux.conf there by hand"
	fi

	mkdir -p "$TERMUX_HOME/.termux"
	target="$TERMUX_HOME/.termux/termux.properties"

	if [ -e "$target" ] && [ "$force" -ne 1 ]; then
		# Never clobber a config file a person may have tuned. Hand them the
		# file and tell them the one command that installs it.
		install -m 0644 "$REPO_ROOT/termux/termux.properties" "$target.new"
		log "existing $target left alone; new config written to $target.new"
		printf '    to use it: mv %q %q && termux-reload-settings\n' "$target.new" "$target"
	else
		install -m 0644 "$REPO_ROOT/termux/termux.properties" "$target"
		log "installed $target"
		if command -v termux-reload-settings >/dev/null 2>&1; then
			termux-reload-settings && log "reloaded Termux settings"
		else
			printf '    run: termux-reload-settings\n'
		fi
	fi
fi

# --- next steps ------------------------------------------------------------

cat <<EOF

Installed:
  gh   -> $BIN_DIR/gh
  ghm  -> $BIN_DIR/ghm

tmux config and key combos are handled above; see the notes printed during
install if either was left alone because you already had one.

Next:
  1. Authenticate. The interactive web flow needs a browser Termux can open:
       gh auth login
     For a headless flow, or if that fails on your ROM:
       gh auth login --with-token < token.txt
     then delete token.txt. A token pasted into a shell history or a synced
     file is a leaked credential; prefer 'gh auth login' where it works.

  2. Try a read-only command first:
       gh repo view

  3. Use it through tmux so Android cannot kill it mid-command:
       ghm pr list          # runs in a session named for this repo
       ghm run list --watch # survives switching apps
       ghm ls               # what sessions exist
       ghm wake             # keep the CPU awake during a long watch

     tmux only reads ~/.tmux.conf when its server starts, so apply the config
     above to any session that is already running:
       tmux source-file ~/.tmux.conf

  4. Detach with the tMX key on the extra keys row (Ctrl-B, d).
EOF
