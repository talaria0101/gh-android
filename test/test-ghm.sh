#!/usr/bin/env bash
# Exercise bin/ghm against a real tmux server, without a phone and without gh.
#
# The interesting behaviour of ghm is entirely in *which tmux calls it makes in
# what order*. Attaching is the one thing a test cannot do, so ghm is put in a
# mode where it prints the tmux command instead of running it, and the test
# asserts on that sequence. Everything else (session naming, argument quoting,
# has-session guards) is real code exercised for real.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GHM="$HERE/../bin/ghm"

# Scratch dir. It lives under the repo rather than /tmp because this sandbox
# mounts /tmp noexec, and the fake tmux below has to be executable.
SCRATCH="${GHM_TEST_SCRATCH:-$HERE/.scratch}"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/bin"

cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

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
	local what="$1" want="$2" got="$3"
	if [ "$want" = "$got" ]; then
		ok "$what"
	else
		no "$what" "want: $want" "got:  $got"
	fi
}

check_contains() {
	local what="$1" needle="$2" haystack="$3"
	case "$haystack" in
	*"$needle"*) ok "$what" ;;
	*) no "$what" "expected to contain: $needle" "got: $haystack" ;;
	esac
}

check_not_contains() {
	local what="$1" needle="$2" haystack="$3"
	case "$haystack" in
	*"$needle"*) no "$what" "should not contain: $needle" "got: $haystack" ;;
	*) ok "$what" ;;
	esac
}

# --- session naming --------------------------------------------------------

# Source ghm's helper functions without running its main case block. Written to
# a file rather than process substitution, which needs /dev/fd.
sed -n '/^session_for_dir()/,/^}/p;/^default_session()/,/^}/p' "$GHM" >"$SCRATCH/helpers.sh"
# shellcheck source=/dev/null
source "$SCRATCH/helpers.sh"

name="$(session_for_dir /data/data/com.termux/files/home/myproject)"
case "$name" in
gh-myproject-*)
	ok "session name keeps the directory and adds a hash: $name"
	;;
*)
	no "session name shape" "got: $name"
	;;
esac

case "$name" in
*.* | *:*)
	no "session name has no . or : (tmux rejects those)" "got: $name"
	;;
*)
	ok "session name has no . or : : $name"
	;;
esac

# Two different directories must not collide, or two checkouts share a screen.
a="$(session_for_dir /tmp/repo-one)"
b="$(session_for_dir /tmp/repo-two)"
check_eq "distinct dirs give distinct sessions" "different" "$([ "$a" != "$b" ] && echo different || echo same)"

# The same directory must be stable, or reattaching never finds the session.
check_eq "same dir is stable across calls" "$a" "$(session_for_dir /tmp/repo-one)"

# A directory name with characters tmux would refuse.
weird="$(session_for_dir "/tmp/my repo.v2:branch")"
case "$weird" in
*.* | *:* | *" "*)
	no "pathological directory name is sanitised" "got: $weird"
	;;
*)
	ok "pathological directory name is sanitised: $weird"
	;;
esac

# Outside a git repo, default_session must still produce something usable.
plain="$(cd /tmp && default_session)"
case "$plain" in
gh-*)
	ok "default_session works outside a git repo: $plain"
	;;
*)
	no "default_session outside a git repo" "got: $plain"
	;;
esac

# --- tmux call sequences ---------------------------------------------------

# A tmux stand-in that records its arguments instead of running them, so
# attaching can be asserted on. It keeps just enough state to be faithful:
# new-session creates a session that has-session then reports, and kill-session
# destroys it. Without that, ghm's post-create has-session guard looks like a
# bug rather than the real guard it is: if `gh` exits immediately, a real tmux
# server destroys the session before ghm can attach.
cat >"$SCRATCH/fake-tmux" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$GHM_TRACE"

state="$GHM_TRACE.sessions"
touch "$state"

case "${1:-}" in
has-session)
	# grep is the last command, so its status is the script's status. A trailing
	# `exit 0` here would make every has-session succeed and quietly turn the
	# rest of this test into a check of nothing.
	grep -qx 'gh-fake' "$state"
	exit $?
	;;
new-session)
	[ -n "${GHM_FAKE_TRANSIENT:-}" ] || printf 'gh-fake\n' >>"$state"
	;;
kill-session)
	# A real kill-session fails when the session is not there. Check first, then
	# clear, so both outcomes are reachable from this one branch.
	if grep -qx 'gh-fake' "$state"; then
		: >"$state"
		exit 0
	fi
	exit 1
	;;
esac
exit 0
FAKE
chmod +x "$SCRATCH/fake-tmux"

run_ghm() {
	export GHM_TRACE="$SCRATCH/trace.txt"
	: >"$GHM_TRACE"
	: >"$GHM_TRACE.sessions"
	[ -n "${GHM_FAKE_EXISTS:-}" ] && printf 'gh-fake\n' >>"$GHM_TRACE.sessions"
	# GHM_FAKE_NO_STATE forces has-session to fail even after a create, which
	# is how a real server behaves when the session's command exited at once.
	[ -n "${GHM_FAKE_NO_STATE:-}" ] && : >"$GHM_TRACE.sessions"
	PATH="$SCRATCH/bin:$PATH" bash "$GHM" "$@" >"$SCRATCH/out.txt" 2>&1 || true
	cat "$GHM_TRACE"
}

cp "$SCRATCH/fake-tmux" "$SCRATCH/bin/tmux"

# New session: create detached, then attach. Nothing may be sent to a session
# that does not exist yet.
out="$(run_ghm pr list)"
check_contains "new session: creates it detached" "new-session -d" "$out"
check_contains "new session: attaches afterwards" "attach-session" "$out"
check_not_contains "new session: does not send-keys into a new session" "send-keys" "$out"

# The create must precede the attach, otherwise ghm attaches to nothing.
create_line="$(printf '%s\n' "$out" | grep -n 'new-session' | cut -d: -f1)"
attach_line="$(printf '%s\n' "$out" | grep -n 'attach-session' | cut -d: -f1)"
if [ -n "$create_line" ] && [ -n "$attach_line" ] && [ "$create_line" -lt "$attach_line" ]; then
	ok "new session: create comes before attach"
else
	no "new session: create comes before attach" "create at $create_line, attach at $attach_line"
fi

# The gh command must be quoted into the tmux shell string, so an argument with
# a space survives to the pane.
out="$(run_ghm pr list --label 'needs review')"
check_contains "argument with a space is quoted" "needs\\ review" "$out"

# Existing session: send the command in, do not create a second one.
out="$(GHM_FAKE_EXISTS=1 run_ghm pr list)"
check_contains "existing session: sends keys in" "send-keys" "$out"
check_not_contains "existing session: does not create a duplicate" "new-session" "$out"

# GHM_SESSION must win over the derived name on every subcommand that picks a
# name, not just the pass-through path. It used to be ignored by attach and kill,
# so `GHM_SESSION=foo ghm kill` killed a different session than the one the
# variable named.
out="$(GHM_SESSION=pinned GHM_FAKE_EXISTS=1 run_ghm pr list)"
check_contains "GHM_SESSION overrides the name for a gh command" "-t =pinned" "$out"

out="$(GHM_SESSION=pinned GHM_FAKE_EXISTS=1 run_ghm attach)"
check_contains "GHM_SESSION overrides the name for attach" "attach-session -t =pinned" "$out"

out="$(GHM_SESSION=pinned GHM_FAKE_EXISTS=1 run_ghm kill)"
check_contains "GHM_SESSION overrides the name for kill" "kill-session -t =pinned" "$out"

out="$(GHM_SESSION=pinned GHM_FAKE_EXISTS=1 run_ghm new pr status)"
check_contains "GHM_SESSION overrides the name for new" "-s =pinned" "$out"

# An explicit name argument still beats GHM_SESSION, since it is more specific.
# Without GHM_FAKE_EXISTS there is no session, so attach stops at the
# has-session check; that is enough to show which name it chose.
out="$(GHM_SESSION=pinned run_ghm attach other)"
check_contains "an explicit name beats GHM_SESSION" "has-session -t =other" "$out"

# kill must target the derived session, and report failure honestly when the
# session is absent rather than claiming it killed something.
out="$(run_ghm kill)"
check_contains "kill targets the session" "kill-session" "$out"

# The success path: kill on a session that exists must report it killed it.
out="$(GHM_FAKE_EXISTS=1 run_ghm kill)"
case "$(cat "$SCRATCH/out.txt")" in
*"killed "*) ok "kill reports success on an existing session" ;;
*) no "kill reports success" "$(cat "$SCRATCH/out.txt")" ;;
esac
if [ -s "$SCRATCH/trace.txt.sessions" ]; then
	no "kill removed the session" "state file still has entries"
else
	ok "kill removed the session"
fi

# new must replace, not refuse: an existing session with a different command
# running in it should be replaced, which is what "new" means.
out="$(GHM_FAKE_EXISTS=1 run_ghm new pr status)"
check_contains "new replaces an existing session" "kill-session" "$out"
check_contains "new recreates the session" "new-session" "$out"

# For the failure path the fake tmux has to actually refuse, which is the case
# ghm is supposed to report as an error.
out="$(GHM_FAKE_NO_STATE=1 run_ghm kill)"
check_contains "kill fails loudly when no session exists" "no session named" "$(cat "$SCRATCH/out.txt")"

# attach to a session that is not there must fail, not silently attach to
# whatever tmux picks by fuzzy name matching.
out="$(GHM_FAKE_NO_STATE=1 run_ghm attach)"
check_contains "attach fails loudly when no session exists" "no session named" "$(cat "$SCRATCH/out.txt")"

# If gh exits instantly the session is gone before ghm can attach. ghm must say
# so rather than hanging on a dead session.
out="$(GHM_FAKE_TRANSIENT=1 run_ghm pr list)"
check_contains "instant gh exit is reported, not hung on" "no session named" "$(cat "$SCRATCH/out.txt")"

# ls must not claim sessions that are not gh's own.
out="$(GHM_FAKE_EXISTS=1 run_ghm ls)"
check_contains "ls lists sessions" "list-sessions" "$out"

# help must not need tmux at all, and must print usage.
out="$(PATH=/usr/bin:/bin bash "$GHM" help 2>&1 || true)"
check_contains "help prints usage" "ghm <gh args...>" "$out"

# Bare `ghm` is a question, not a request to run `gh ''`. It must print usage
# rather than creating a session running gh with an empty argument.
#
# Check the tmux trace, not stdout: the fake tmux records argv to a file, so
# looking for "new-session" in ghm's output could never fail.
export GHM_TRACE="$SCRATCH/trace.txt"
: >"$GHM_TRACE"
: >"$GHM_TRACE.sessions"
bare_out="$(PATH="$SCRATCH/bin:$PATH" bash "$GHM" 2>&1 || true)"
check_contains "bare ghm prints usage" "ghm <gh args...>" "$bare_out"
if [ -s "$GHM_TRACE" ]; then
	no "bare ghm does not call tmux at all" "trace contains: $(head -1 "$GHM_TRACE")"
else
	ok "bare ghm does not call tmux at all"
fi

# wake/unwake are Termux-only; without the helper they must say so, not pretend.
# ghm exits non-zero here on purpose, so the command substitution needs || true.
out="$(PATH=/usr/bin:/bin bash "$GHM" wake 2>&1 || true)"
check_contains "wake explains the missing helper" "termux-wake-lock" "$out"

# --- syntax ----------------------------------------------------------------

if bash -n "$GHM" 2>/dev/null; then
	ok "bin/ghm parses"
else
	no "bin/ghm parses" "$(bash -n "$GHM" 2>&1)"
fi

if bash -n "$HERE/../build/build-gh.sh" 2>/dev/null; then
	ok "build/build-gh.sh parses"
else
	no "build/build-gh.sh parses" "$(bash -n "$HERE/../build/build-gh.sh" 2>&1)"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
