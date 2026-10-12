#!/usr/bin/env bash
# Rehearse install.sh against a fake Termux prefix, on a machine that is not a
# phone.
#
# A phone is not available here, so this substitutes what it can and says what
# it cannot:
#
#   * the arch gate is exercised for real by faking `uname -m`;
#   * the copy, checksum and key-config steps are real, in a scratch prefix;
#   * "does the installed gh actually run" cannot be real, because an aarch64
#     binary will not exec on this host. That one check is inverted: instead of
#     trusting it, the test asserts that install.sh REFUSES to continue when gh
#     will not run, which is the behaviour that matters on a device.
#
# The aarch64 binary's runtime behaviour is covered separately by
# test-binary.sh, which runs it under qemu-aarch64.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"

SCRATCH="${GHM_TEST_SCRATCH:-$ROOT/.scratch}"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"

passed=0
failed=0

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

cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

# A fake prefix and a fake uname that reports a phone, since install.sh gates
# on both.
mkdir -p "$SCRATCH/usr/bin" "$SCRATCH/home"
mkdir -p "$SCRATCH/fakebin"

cat >"$SCRATCH/fakebin/uname" <<'FAKE'
#!/bin/bash
[ "${1:-}" = "-m" ] && echo aarch64 || /usr/bin/uname "$@"
FAKE
chmod +x "$SCRATCH/fakebin/uname"
check_eq "fake uname reports a phone" "aarch64" "$(PATH="$SCRATCH/fakebin:$PATH" uname -m)"

# install.sh needs git and tmux to be present, or it stops before installing
# anything. If this host lacks one of them, say so rather than reporting a
# suite that quietly proved less than it claims.
for tool in git tmux sha256sum install; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		printf '  SKIP  %s is not installed on this host; install.sh gates on it\n' "$tool"
		skipped_tool=1
	fi
done
if [ -n "${skipped_tool:-}" ]; then
	printf '\n0 passed, 0 failed (suite cannot run)\n'
	exit 0
fi

# --- a missing prefix is refused ------------------------------------------
# Note: x86_64 used to be refused outright, because only arm64 was ever built.
# amd64 is a supported arch now, so an x86_64 device installs gh-amd64; the
# per-arch cases below cover that. What is left to check here is that a missing
# prefix is still refused.

# Restore the phone-reporting uname for the remaining cases.
cat >"$SCRATCH/fakebin/uname" <<'FAKE'
#!/bin/bash
[ "${1:-}" = "-m" ] && echo aarch64 || /usr/bin/uname "$@"
FAKE
chmod +x "$SCRATCH/fakebin/uname"
out="$(PATH="$SCRATCH/fakebin:$PATH" PREFIX="$SCRATCH/nosuchprefix" bash "$ROOT/install.sh" 2>&1 || true)"
case "$out" in
*"does not exist"*) ok "a missing prefix is refused" ;;
*) no "missing prefix refused" "$out" ;;
esac

# --- refuses a tampered binary --------------------------------------------
# A checksum mismatch must stop the install. Copy the dist tree so the real
# dist/SHA256SUMS is not touched.
mkdir -p "$SCRATCH/repo"
cp -r "$ROOT/bin" "$ROOT/build" "$ROOT/dist" "$ROOT/termux" "$ROOT/install.sh" "$SCRATCH/repo/"
printf 'tampered\n' >>"$SCRATCH/repo/dist/gh-arm64"
# Start from an empty prefix: an earlier case may have left a gh in place, and
# "already exists" would mask the thing this case is checking.
rm -f "$SCRATCH/usr/bin/gh"

out="$(PATH="$SCRATCH/fakebin:$PATH" PREFIX="$SCRATCH/usr" TERMUX_HOME="$SCRATCH/home" \
	bash "$SCRATCH/repo/install.sh" 2>&1 || true)"
case "$out" in
*"checksum mismatch"*) ok "a tampered binary is refused" ;;
*) no "tampered binary refused" "$out" ;;
esac
if [ -e "$SCRATCH/usr/bin/gh" ]; then
	no "tampered binary was not installed" "$SCRATCH/usr/bin/gh exists"
else
	ok "tampered binary was not installed"
fi

# --- refuses when the binary will not run on the device -------------------
# Remove the manifest first, so this case reaches the exec check instead of
# stopping at the checksum: a mode-000 file fails both, and the checksum firing
# first is correct but tests nothing new here.
rm -rf "$SCRATCH/repo"
mkdir -p "$SCRATCH/repo"
cp -r "$ROOT/bin" "$ROOT/build" "$ROOT/dist" "$ROOT/termux" "$ROOT/install.sh" "$SCRATCH/repo/"
rm -f "$SCRATCH/repo/dist/SHA256SUMS"
printf '#!/bin/sh\nexit 127\n' >"$SCRATCH/repo/dist/gh-arm64"
chmod 000 "$SCRATCH/repo/dist/gh-arm64"
out="$(PATH="$SCRATCH/fakebin:$PATH" PREFIX="$SCRATCH/usr" TERMUX_HOME="$SCRATCH/home" \
	bash "$SCRATCH/repo/install.sh" --force 2>&1 || true)"
case "$out" in
*"Permission denied"* | *"cannot"*)
	ok "a binary that cannot be copied is reported, not installed as if fine" ;;
*) no "unreadable binary reported" "$out" ;;
esac
if [ -e "$SCRATCH/usr/bin/gh" ]; then
	no "unreadable binary did not reach \$PREFIX/bin" "$SCRATCH/usr/bin/gh exists"
else
	ok "unreadable binary did not reach \$PREFIX/bin"
fi

# Second: a binary that installs but then fails to run, which is what the
# `gh --version` gate exists for. A stub that exits non-zero on --version is
# exactly that case, and the mode-000 test above never reaches it.
#
# Fresh copy of the repo: the case above left a mode-000 file, which cannot be
# rewritten in place.
rm -rf "$SCRATCH/repo"
mkdir -p "$SCRATCH/repo"
cp -r "$ROOT/bin" "$ROOT/build" "$ROOT/dist" "$ROOT/termux" "$ROOT/install.sh" "$SCRATCH/repo/"
rm -f "$SCRATCH/repo/dist/SHA256SUMS"
printf '#!/bin/sh\nif [ "$1" = "--version" ]; then exit 127; fi\nexit 0\n' \
	>"$SCRATCH/repo/dist/gh-arm64"
chmod +x "$SCRATCH/repo/dist/gh-arm64"
rm -f "$SCRATCH/usr/bin/gh"
out="$(PATH="$SCRATCH/fakebin:$PATH" PREFIX="$SCRATCH/usr" TERMUX_HOME="$SCRATCH/home" \
	bash "$SCRATCH/repo/install.sh" 2>&1 || true)"
case "$out" in
*"did not run on this device"*)
	ok "a binary that installs but will not run is caught by the --version gate" ;;
*) no "unrunnable binary not caught by the --version gate" "$out" ;;
esac
case "$out" in
*"installing ghm"*) no "install stops before ghm on a broken gh" "ghm was installed anyway" ;;
*) ok "install stops before ghm on a broken gh" ;;
esac

# The gate must run the binary it just installed, not whatever `gh` resolves to
# on PATH. A user who ran `pkg install gh` first has a second gh on PATH, and a
# bare `gh --version` would pass while the installed one is broken. Put a
# working gh on PATH and check the gate still refuses.
printf '#!/bin/sh\n[ "$1" = "--version" ] && echo "gh version 9.9.9 (system)"\nexit 0\n' \
	>"$SCRATCH/fakebin/gh"
chmod +x "$SCRATCH/fakebin/gh"
rm -f "$SCRATCH/usr/bin/gh"
out="$(PATH="$SCRATCH/fakebin:$PATH" PREFIX="$SCRATCH/usr" TERMUX_HOME="$SCRATCH/home" \
	bash "$SCRATCH/repo/install.sh" 2>&1 || true)"
case "$out" in
*"did not run on this device"*)
	ok "the --version gate uses the installed binary, not one already on PATH" ;;
*) no "the --version gate was satisfied by a gh on PATH" "$out" ;;
esac
rm -f "$SCRATCH/fakebin/gh"

# --- refuses to clobber without --force -----------------------------------
rm -rf "$SCRATCH/repo"
mkdir -p "$SCRATCH/repo"
cp -r "$ROOT/bin" "$ROOT/build" "$ROOT/dist" "$ROOT/termux" "$ROOT/install.sh" "$SCRATCH/repo/"
touch "$SCRATCH/usr/bin/gh"
out="$(PATH="$SCRATCH/fakebin:$PATH" PREFIX="$SCRATCH/usr" TERMUX_HOME="$SCRATCH/home" \
	bash "$SCRATCH/repo/install.sh" 2>&1 || true)"
case "$out" in
*"already exists"*) ok "existing gh is protected without --force" ;;
*) no "existing gh protected" "$out" ;;
esac

# --- existing termux.properties is never silently replaced ----------------
# No --force here: without it the properties file must survive untouched, and
# the new one must be offered alongside it as .new.
#
# The binary has to be runnable to get this far, since install.sh refuses to
# continue past a binary that will not exec and that check comes first. A shell
# stub stands in for the aarch64 binary, which cannot exec on this host at all.
printf '#!/bin/sh\n[ "$1" = "--version" ] && echo "gh version 9.9.9 (stub)"\nexit 0\n' \
	>"$SCRATCH/repo/dist/gh-arm64"
chmod +x "$SCRATCH/repo/dist/gh-arm64"
rm -f "$SCRATCH/repo/dist/SHA256SUMS"
rm -f "$SCRATCH/usr/bin/gh"
mkdir -p "$SCRATCH/home/.termux"
printf '# my own settings\n' >"$SCRATCH/home/.termux/termux.properties"

out="$(PATH="$SCRATCH/fakebin:$PATH" PREFIX="$SCRATCH/usr" TERMUX_HOME="$SCRATCH/home" \
	bash "$SCRATCH/repo/install.sh" 2>&1 || true)"
case "$out" in
*"left alone"*) ok "an existing termux.properties is left alone" ;;
*) no "existing termux.properties protected" "$out" ;;
esac
check_eq "existing termux.properties is byte-for-byte untouched" \
	"# my own settings" "$(cat "$SCRATCH/home/.termux/termux.properties")"
if [ -f "$SCRATCH/home/.termux/termux.properties.new" ]; then
	ok "the new config is offered as .new instead of replacing the old one"
else
	no "new config offered as .new" "no .new file was written"
fi

# A full clean install, to prove the happy path end to end in the fake prefix:
# gh, ghm and the properties file all land where install.sh says they will.
rm -f "$SCRATCH/home/.termux/termux.properties" "$SCRATCH/usr/bin/gh" "$SCRATCH/usr/bin/ghm"
out="$(PATH="$SCRATCH/fakebin:$PATH" PREFIX="$SCRATCH/usr" TERMUX_HOME="$SCRATCH/home" \
	bash "$SCRATCH/repo/install.sh" 2>&1 || true)"
if [ -x "$SCRATCH/usr/bin/gh" ] && [ -x "$SCRATCH/usr/bin/ghm" ]; then
	ok "clean install puts executable gh and ghm in \$PREFIX/bin"
else
	no "clean install placed gh and ghm" "gh=$([ -e "$SCRATCH/usr/bin/gh" ] && echo yes || echo no) ghm=$([ -e "$SCRATCH/usr/bin/ghm" ] && echo yes || echo no)"
fi
if [ -f "$SCRATCH/home/.termux/termux.properties" ]; then
	ok "clean install writes termux.properties"
else
	no "clean install writes termux.properties" "$out"
fi
if [ -f "$SCRATCH/home/.tmux.conf" ]; then
	ok "clean install writes ~/.tmux.conf"
else
	no "clean install writes ~/.tmux.conf" "$out"
fi
if [ -x "$SCRATCH/usr/bin/ghm" ]; then
	# ghm must work from the installed location, not just from the repo.
	installed_help="$(PREFIX="$SCRATCH/usr" "$SCRATCH/usr/bin/ghm" help 2>&1 || true)"
	case "$installed_help" in
	*"ghm <gh args...>"*) ok "installed ghm runs from \$PREFIX/bin" ;;
	*) no "installed ghm runs" "$installed_help" ;;
	esac
fi

# An existing ~/.tmux.conf is personal and must not be replaced silently, by the
# same rule as termux.properties.
rm -f "$SCRATCH/usr/bin/gh" "$SCRATCH/usr/bin/ghm" "$SCRATCH/home/.tmux.conf"
printf '# my own tmux settings\n' >"$SCRATCH/home/.tmux.conf"
out="$(PATH="$SCRATCH/fakebin:$PATH" PREFIX="$SCRATCH/usr" TERMUX_HOME="$SCRATCH/home" \
	bash "$SCRATCH/repo/install.sh" 2>&1 || true)"
check_eq "existing ~/.tmux.conf is byte-for-byte untouched" \
	"# my own tmux settings" "$(cat "$SCRATCH/home/.tmux.conf")"
if [ -f "$SCRATCH/home/.tmux.conf.new" ]; then
	ok "a new ~/.tmux.conf is offered as .new"
else
	no "new ~/.tmux.conf offered as .new" "no .new file was written"
fi

# `bash -n` cannot catch a function that is called before it is defined, which
# is a real bug that shipped once in install.sh: --help exited 127 because bash
# had not read the usage() definition yet. Run the options for real.
out="$(bash "$ROOT/install.sh" --help 2>&1)"
case "$out" in
*"--no-keys"*) ok "install.sh --help prints usage" ;;
*) no "install.sh --help prints usage" "$out" ;;
esac
case "$out" in
*"command not found"*) no "install.sh --help resolves its own helpers" "$out" ;;
*) ok "install.sh --help resolves its own helpers" ;;
esac
bash "$ROOT/install.sh" -h >/dev/null 2>&1
check_eq "install.sh -h exits 0" "0" "$?"
# Both of these commands exit non-zero on purpose, and `set -e` aborts the suite
# on a failing command substitution, so append `|| true` and read the status
# separately where it matters.
out="$(bash "$ROOT/install.sh" --bogus 2>&1 || true)"
case "$out" in
*"unknown option"*) ok "install.sh rejects an unknown option" ;;
*) no "install.sh rejects an unknown option" "$out" ;;
esac
bogus_status=0
bash "$ROOT/install.sh" --bogus >/dev/null 2>&1 || bogus_status=$?
check_eq "install.sh rejects an unknown option with a non-zero status" "1" "$bogus_status"

# --no-keys must skip both config files, not just the properties one. It used to
# write ~/.tmux.conf regardless, while the help text said otherwise.
rm -f "$SCRATCH/usr/bin/gh" "$SCRATCH/usr/bin/ghm"
rm -f "$SCRATCH/home/.tmux.conf"
rm -rf "$SCRATCH/home/.termux"
out="$(PATH="$SCRATCH/fakebin:$PATH" PREFIX="$SCRATCH/usr" TERMUX_HOME="$SCRATCH/home" \
	bash "$SCRATCH/repo/install.sh" --no-keys 2>&1 || true)"
if [ -f "$SCRATCH/home/.termux/termux.properties" ]; then
	no "--no-keys skips the properties install" "termux.properties was written anyway"
else
	ok "--no-keys skips the properties install"
fi
if [ -f "$SCRATCH/home/.tmux.conf" ]; then
	no "--no-keys skips the ~/.tmux.conf install" "~/.tmux.conf was written anyway"
else
	ok "--no-keys skips the ~/.tmux.conf install"
fi
# ...while still installing the binaries, which is the point of the flag.
if [ -x "$SCRATCH/usr/bin/gh" ] && [ -x "$SCRATCH/usr/bin/ghm" ]; then
	ok "--no-keys still installs gh and ghm"
else
	no "--no-keys still installs gh and ghm" "$out"
fi

# The install must record what it installed, so --uninstall can remove exactly
# those paths. Nothing else writes this file.
if [ -f "$SCRATCH/home/.gh-android-installed" ]; then
	ok "install records the paths it installed"
else
	no "install records the paths it installed" "no $SCRATCH/home/.gh-android-installed"
fi
if [ -e "$SCRATCH/home/.gh-android-installed" ]; then
	if grep -qx "$SCRATCH/usr/bin/gh" "$SCRATCH/home/.gh-android-installed" &&
		grep -qx "$SCRATCH/usr/bin/ghm" "$SCRATCH/home/.gh-android-installed"; then
		ok "the install record names the gh and ghm it installed"
	else
		no "the install record names the gh and ghm it installed" \
			"$(cat "$SCRATCH/home/.gh-android-installed")"
	fi
fi

# --uninstall must refuse when there is no record of an install, rather than
# deleting whatever gh happens to be in $PREFIX/bin. That binary may have come
# from `pkg install gh`.
#
# Stand a gh in place first: the point is that it survives, not that it is absent.
rm -f "$SCRATCH/home/.gh-android-installed"
touch "$SCRATCH/usr/bin/gh" "$SCRATCH/usr/bin/ghm"
out="$(PATH="$SCRATCH/fakebin:$PATH" PREFIX="$SCRATCH/usr" TERMUX_HOME="$SCRATCH/home" \
	bash "$SCRATCH/repo/install.sh" --uninstall 2>&1 || true)"
case "$out" in
*"no record"*) ok "--uninstall refuses without an install record" ;;
*) no "--uninstall refused" "$out" ;;
esac
if [ -e "$SCRATCH/usr/bin/gh" ]; then
	ok "--uninstall left the unrecorded gh alone"
else
	no "--uninstall deleted a gh it never installed"
fi

# With a record, uninstall removes exactly those paths and clears the record.
printf '%s\n%s\n' "$SCRATCH/usr/bin/gh" "$SCRATCH/usr/bin/ghm" >"$SCRATCH/home/.gh-android-installed"
touch "$SCRATCH/usr/bin/gh" "$SCRATCH/usr/bin/ghm"
out="$(PATH="$SCRATCH/fakebin:$PATH" PREFIX="$SCRATCH/usr" TERMUX_HOME="$SCRATCH/home" \
	bash "$SCRATCH/repo/install.sh" --uninstall 2>&1 || true)"
if [ -e "$SCRATCH/usr/bin/gh" ] || [ -e "$SCRATCH/usr/bin/ghm" ]; then
	no "--uninstall removed the recorded paths" "gh=$([ -e "$SCRATCH/usr/bin/gh" ] && echo present || echo gone) ghm=$([ -e "$SCRATCH/usr/bin/ghm" ] && echo present || echo gone)"
else
	ok "--uninstall removed the recorded paths"
fi
if [ -f "$SCRATCH/home/.gh-android-installed" ]; then
	no "--uninstall cleared the install record"
else
	ok "--uninstall cleared the install record"
fi

# A record must not be able to point outside $PREFIX/bin, or a tampered record
# would turn uninstall into an arbitrary delete. It must also not be reported
# as a clean success: that entry was not removed.
printf '%s\n' "$SCRATCH/important.txt" >"$SCRATCH/home/.gh-android-installed"
touch "$SCRATCH/important.txt"
out="$(PATH="$SCRATCH/fakebin:$PATH" PREFIX="$SCRATCH/usr" TERMUX_HOME="$SCRATCH/home" \
	bash "$SCRATCH/repo/install.sh" --uninstall 2>&1 || true)"
if [ -e "$SCRATCH/important.txt" ]; then
	ok "--uninstall refuses a record pointing outside \$PREFIX/bin"
else
	no "--uninstall deleted a path outside \$PREFIX/bin" "$out"
fi
case "$out" in
*"not under"*) ok "--uninstall says why it skipped an out-of-prefix path" ;;
*) no "--uninstall silent about a skipped path" "$out" ;;
esac

# A dangling symlink must still be removed. `[ -e ]` is false for one, so a
# naive test skips it and then deletes the record, leaving the link behind.
rm -f "$SCRATCH/usr/bin/gh" "$SCRATCH/usr/bin/ghm"
ln -s "$SCRATCH/nothing-here" "$SCRATCH/usr/bin/gh"
printf '%s\n%s\n' "$SCRATCH/usr/bin/gh" "$SCRATCH/usr/bin/ghm" >"$SCRATCH/home/.gh-android-installed"
out="$(PATH="$SCRATCH/fakebin:$PATH" PREFIX="$SCRATCH/usr" TERMUX_HOME="$SCRATCH/home" \
	bash "$SCRATCH/repo/install.sh" --uninstall 2>&1 || true)"
if [ -L "$SCRATCH/usr/bin/gh" ]; then
	no "--uninstall removed a dangling symlink" "$out"
else
	ok "--uninstall removed a dangling symlink"
fi

# --- per-arch selection -----------------------------------------------------
#
# The repo now ships arm64, arm and amd64. Each of these checks one arch's
# install path in a clean prefix, using a runnable stub for gh where the real
# binary is a foreign architecture.

# A stub that satisfies the --version gate, so the rest of the install runs.
make_stub_repo() {
	local dest="$1"
	rm -rf "$dest"
	mkdir -p "$dest/dist"
	cp -r "$ROOT/bin" "$ROOT/build" "$ROOT/termux" "$ROOT/install.sh" "$dest/"
	printf '#!/bin/sh\n[ "$1" = "--version" ] && echo "gh version 9.9.9 (stub)"\nexit 0\n' \
		>"$dest/dist/gh-arm64"
	cp "$dest/dist/gh-arm64" "$dest/dist/gh-arm"
	cp "$dest/dist/gh-arm64" "$dest/dist/gh-amd64"
	chmod +x "$dest/dist/gh-arm64" "$dest/dist/gh-arm" "$dest/dist/gh-amd64"
	(cd "$dest/dist" && sha256sum gh-arm64 gh-arm gh-amd64 >SHA256SUMS)
}

fake_uname() {
	printf '#!/bin/bash\n[ "${1:-}" = "-m" ] && echo %s || /usr/bin/uname "$@"\n' "$1" \
		>"$SCRATCH/fakebin/uname"
	chmod +x "$SCRATCH/fakebin/uname"
}

# Each arch must select its own binary and ignore the others.
#
# The stubs are made distinguishable by the ONLY thing that differs: the arch
# name inside them. An earlier version of this check grepped for "stub for $arch"
# with a `|| --version` fallback, which could never fail: the pattern matched
# "stub for arm64" as a substring of itself, and every stub answered --version
# with exit 0. Run the installed binary and require it to print its own name,
# so installing the wrong file is detectable.
for pair in "arm64:aarch64" "arm:armv7l" "amd64:x86_64"; do
	arch="${pair%%:*}"
	machine="${pair##*:}"
	make_stub_repo "$SCRATCH/archrepo"
	fake_uname "$machine"
	prefix="$SCRATCH/arch-$arch"
	rm -rf "$prefix"
	mkdir -p "$prefix/bin"

	# Every dist stub is labelled with its own arch, so the installed binary
	# identifies which file was copied.
	for a in arm64 arm amd64; do
		printf '#!/bin/sh\necho "I-AM-%s"\nexit 0\n' "$a" >"$SCRATCH/archrepo/dist/gh-$a"
		chmod +x "$SCRATCH/archrepo/dist/gh-$a"
	done
	(cd "$SCRATCH/archrepo/dist" && sha256sum gh-arm64 gh-arm gh-amd64 >SHA256SUMS)

	out="$(PATH="$SCRATCH/fakebin:$PATH" PREFIX="$prefix" TERMUX_HOME="$SCRATCH/home" \
		bash "$SCRATCH/archrepo/install.sh" 2>&1 || true)"
	case "$out" in
	*"architecture: $machine"*) ok "$arch: detects uname -m $machine" ;;
	*) no "$arch: detects uname -m $machine" "$out" ;;
	esac
	case "$out" in
	*"checksum OK for gh-$arch"*) ok "$arch: verifies its own checksum" ;;
	*) no "$arch: verifies its own checksum" "$out" ;;
	esac
	if [ -x "$prefix/bin/gh" ]; then
		ok "$arch: installs gh into \$PREFIX/bin"
	else
		no "$arch: installs gh into \$PREFIX/bin" "$out"
	fi
	# The decisive check: run it. A wrong-arch install prints a different name.
	installed="$("$prefix/bin/gh" 2>/dev/null || true)"
	check_eq "$arch: installed the binary for that arch" "I-AM-$arch" "$installed"
done

# The binary-selection check above must be able to fail. Confirm by making the
# wrong binary the only one present: installing on an arm64 device with only
# gh-arm available must not silently install gh-arm.
make_stub_repo "$SCRATCH/archrepo"
fake_uname aarch64
rm -f "$SCRATCH/archrepo/dist/gh-arm64" "$SCRATCH/archrepo/dist/gh-amd64"
printf '#!/bin/sh\necho "I-AM-arm"\nexit 0\n' >"$SCRATCH/archrepo/dist/gh-arm"
chmod +x "$SCRATCH/archrepo/dist/gh-arm"
(cd "$SCRATCH/archrepo/dist" && sha256sum gh-arm >SHA256SUMS)
prefix="$SCRATCH/arch-wrongbinary"
rm -rf "$prefix"
mkdir -p "$prefix/bin"
out="$(PATH="$SCRATCH/fakebin:$PATH" PREFIX="$prefix" TERMUX_HOME="$SCRATCH/home" \
	bash "$SCRATCH/archrepo/install.sh" 2>&1 || true)"
if [ -e "$prefix/bin/gh" ]; then
	no "a wrong-arch binary was installed as if correct" "$(cat "$prefix/bin/gh" 2>/dev/null)"
else
	ok "a wrong-arch binary is never installed in place of the right one"
fi

# A corrupt binary for another arch must not stop this arch installing.
#
# The manifest must be written BEFORE the sibling is corrupted, otherwise the
# recorded hash matches the corrupt file and the test proves nothing. An earlier
# version regenerated the manifest afterwards and so passed for the wrong
# reason, never reaching install.sh's per-line fallback.
make_stub_repo "$SCRATCH/archrepo"
fake_uname armv7l
prefix="$SCRATCH/arch-sibling"
rm -rf "$prefix"
mkdir -p "$prefix/bin"
printf 'corrupt\n' >>"$SCRATCH/archrepo/dist/gh-amd64"
out="$(PATH="$SCRATCH/fakebin:$PATH" PREFIX="$prefix" TERMUX_HOME="$SCRATCH/home" \
	bash "$SCRATCH/archrepo/install.sh" 2>&1 || true)"
case "$out" in
*"checksum OK for gh-arm"*) ok "a corrupt sibling arch does not block this arch" ;;
*) no "a corrupt sibling arch blocked this arch" "$out" ;;
esac

# And the converse: a corrupt binary for THIS arch must still stop the install.
make_stub_repo "$SCRATCH/archrepo"
fake_uname armv7l
prefix="$SCRATCH/arch-selfcorrupt"
rm -rf "$prefix"
mkdir -p "$prefix/bin"
printf 'corrupt\n' >>"$SCRATCH/archrepo/dist/gh-arm"
out="$(PATH="$SCRATCH/fakebin:$PATH" PREFIX="$prefix" TERMUX_HOME="$SCRATCH/home" \
	bash "$SCRATCH/archrepo/install.sh" 2>&1 || true)"
case "$out" in
*"checksum mismatch for gh-arm"*) ok "a corrupt binary for this arch is refused" ;;
*) no "a corrupt binary for this arch was not refused" "$out" ;;
esac
if [ -e "$prefix/bin/gh" ]; then
	no "a corrupt binary reached \$PREFIX/bin"
else
	ok "a corrupt binary did not reach \$PREFIX/bin"
fi

# A manifest with no entry for this arch must not silently claim success.
make_stub_repo "$SCRATCH/archrepo"
fake_uname armv7l
printf '%s\n' "$SCRATCH/archrepo/dist/gh-arm64" >"$SCRATCH/archrepo/dist/SHA256SUMS"
prefix="$SCRATCH/arch-noentry"
rm -rf "$prefix"
mkdir -p "$prefix/bin"
out="$(PATH="$SCRATCH/fakebin:$PATH" PREFIX="$prefix" TERMUX_HOME="$SCRATCH/home" \
	bash "$SCRATCH/archrepo/install.sh" 2>&1 || true)"
case "$out" in
*"no entry for gh-arm"*) ok "a manifest with no entry for this arch says so" ;;
*) no "a missing manifest entry was silent" "$out" ;;
esac

# A missing binary must point at the release, since CI publishes the binaries
# there rather than committing them.
make_stub_repo "$SCRATCH/archrepo"
rm -f "$SCRATCH/archrepo/dist/gh-arm"
fake_uname armv7l
prefix="$SCRATCH/arch-missing"
rm -rf "$prefix"
mkdir -p "$prefix/bin"
out="$(PATH="$SCRATCH/fakebin:$PATH" PREFIX="$prefix" TERMUX_HOME="$SCRATCH/home" \
	bash "$SCRATCH/archrepo/install.sh" 2>&1 || true)"
case "$out" in
*"gh release download"*) ok "a missing binary points at the release download" ;;
*) no "a missing binary did not point at the release" "$out" ;;
esac
case "$out" in
*"dist/gh-arm"*) ok "the missing-binary message names this arch's file" ;;
*) no "the missing-binary message did not name the file" "$out" ;;
esac
# It must also mention the local build, for someone who wants a version that is
# not released.
case "$out" in
*"ANDROID_NDK_HOME"*) ok "a missing binary also offers the local build" ;;
*) no "a missing binary did not offer the local build" "$out" ;;
esac
# The message is printed from a repo copy with no git remote. That must not abort
# the script before it prints anything: an assignment whose command substitution
# fails trips `set -e`, and this file does derive the repo slug from git.
case "$out" in
*"architecture: armv7l"*) ok "a missing binary reports the detected architecture" ;;
*) no "a missing binary did not report the architecture" "$out" ;;
esac
if [ "$(printf '%s' "$out" | grep -c 'not found for this device')" -eq 1 ]; then
	ok "the missing-binary message is printed exactly once, in full"
else
	no "the missing-binary message was truncated or repeated" "$out"
fi

# Restore the arm64 uname for the remaining cases.
fake_uname aarch64

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
