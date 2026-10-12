#!/usr/bin/env bash
# Run every check in this repo.
#
#   ./test/run-tests.sh
#
# On a phone none of this is needed; the point of these tests is to catch
# mistakes in the wrapper, the key config and the build on a machine where
# mistakes are cheap. Two of them need tools that may not be installed:
#
#   * the extra-keys check wants a JDK and org.json on the classpath, because
#     Termux parses the properties file with java.util.Properties and org.json.
#     Without them it is skipped, not silently passed.
#   * the binary check wants qemu-aarch64 to run the aarch64 build.

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"

JSON_JAR="${JSON_JAR:-}"
if [ -z "$JSON_JAR" ]; then
	for candidate in "$HERE/json.jar" "$ROOT/.scratch/json.jar" /tmp/json.jar; do
		[ -f "$candidate" ] && JSON_JAR="$candidate" && break
	done
fi

JAVA="${JAVA:-}"
if [ -z "$JAVA" ]; then
	for candidate in /usr/lib/jvm/openjdk25/bin/java /usr/lib/jvm/default-jdk/bin/java "$(command -v java 2>/dev/null || true)"; do
		[ -n "$candidate" ] && [ -x "$candidate" ] && JAVA="$candidate" && break
	done
fi

failed=0
ran=0
skipped=0

run_suite() {
	local name="$1"
	shift
	printf '\n=== %s\n' "$name"
	ran=$((ran + 1))
	if "$@"; then
		return 0
	fi
	failed=$((failed + 1))
	return 1
}

# --- shell syntax for every shipped script ---------------------------------

printf '\n=== shell syntax\n'
ran=$((ran + 1))
syntax_ok=1
for script in "$ROOT/install.sh" "$ROOT/build/build-gh.sh" "$ROOT/bin/ghm"; do
	if bash -n "$script" 2>/dev/null; then
		printf '  ok    %s parses\n' "${script#"$ROOT"/}"
	else
		printf '  FAIL  %s\n' "${script#"$ROOT"/}"
		bash -n "$script" 2>&1 | sed 's/^/        /'
		syntax_ok=0
	fi
done
[ "$syntax_ok" -eq 1 ] || failed=$((failed + 1))

# --- the wrapper ----------------------------------------------------------

run_suite "ghm wrapper" bash "$HERE/test-ghm.sh"

# --- install rehearsal ----------------------------------------------------

run_suite "install.sh rehearsal" bash "$HERE/test-install.sh"

# --- the binary -----------------------------------------------------------

run_suite "gh binary" bash "$HERE/test-binary.sh"

# --- tmux config loads ----------------------------------------------------

printf '\n=== tmux.conf\n'
ran=$((ran + 1))
if command -v tmux >/dev/null 2>&1; then
	# Load the config into a throwaway server and treat any output as an error.
	# A single bad line makes tmux report it and skip the rest, which on a phone
	# means quietly missing key bindings.
	tmux_out="$(tmux -f "$ROOT/termux/tmux.conf" -L ghmconfcheck start-server \; \
		source-file "$ROOT/termux/tmux.conf" 2>&1)"
	tmux -f /dev/null -L ghmconfcheck kill-server >/dev/null 2>&1
	if [ -z "$tmux_out" ]; then
		printf '  ok    tmux.conf loads with no errors\n'
		if tmux -f "$ROOT/termux/tmux.conf" -L ghmconfcheck2 start-server \; \
			source-file "$ROOT/termux/tmux.conf" 2>/dev/null &&
			[ "$(tmux -f /dev/null -L ghmconfcheck2 show-options -g history-limit 2>/dev/null)" = "history-limit 50000" ]; then
			printf '  ok    history-limit took effect\n'
		else
			printf '  FAIL  history-limit did not take effect\n'
			failed=$((failed + 1))
		fi
		tmux -f /dev/null -L ghmconfcheck2 kill-server >/dev/null 2>&1
	else
		printf '  FAIL  tmux.conf reported errors:\n'
		printf '%s\n' "$tmux_out" | sed 's/^/        /'
		failed=$((failed + 1))
	fi
else
	skipped=$((skipped + 1))
	printf '  SKIP  tmux not installed\n'
fi

# --- the key config -------------------------------------------------------

printf '\n=== termux extra-keys\n'
# Check that the paths are usable, not merely that the variables are set: an
# exported JAVA=/nonexistent is set but broken, and treating that as "found"
# turns a skip into a confusing failure.
if [ -n "$JAVA" ] && [ -x "$JAVA" ] && [ -n "$JSON_JAR" ] && [ -f "$JSON_JAR" ]; then
	ran=$((ran + 1))
	if "$JAVA" -cp "$JSON_JAR" "$HERE/CheckExtraKeys.java" "$ROOT/termux/termux.properties"; then
		:
	else
		failed=$((failed + 1))
	fi
else
	skipped=$((skipped + 1))
	printf '  SKIP  no usable JDK + org.json found (JAVA=%s JSON_JAR=%s)\n' \
		"${JAVA:-unset}" "${JSON_JAR:-unset}"
	printf '        To run this check:\n'
	printf '          curl -sLo test/json.jar https://repo1.maven.org/maven2/org/json/json/20240303/json-20240303.jar\n'
	printf '          JAVA=/path/to/java JSON_JAR=$PWD/test/json.jar %s\n' "$0"
fi

# --- README key tables match the properties file ---------------------------
#
# The tables in README.md and the JSON in termux.properties are both written by
# hand. They did drift, with the README claiming popups the file did not have,
# which fails silently for a user who swipes up and gets nothing. This fails
# when they disagree again.

printf '\n=== README key tables\n'
if [ -n "$JAVA" ] && [ -x "$JAVA" ] && [ -n "$JSON_JAR" ] && [ -f "$JSON_JAR" ]; then
	ran=$((ran + 1))
	if "$JAVA" -cp "$JSON_JAR" "$HERE/CheckReadmeTables.java" \
		"$ROOT/termux/termux.properties" "$ROOT/README.md"; then
		:
	else
		failed=$((failed + 1))
	fi
else
	skipped=$((skipped + 1))
	printf '  SKIP  needs the JDK and org.json as above\n'
fi

printf '\n===================================\n'
if [ "$failed" -eq 0 ]; then
	printf 'all suites passed (%d run, %d skipped)\n' "$ran" "$skipped"
	exit 0
fi
printf '%d suite(s) FAILED (%d run, %d skipped)\n' "$failed" "$ran" "$skipped"
exit 1
