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

# javac, for the reason given at compile_java below. Look beside the chosen java
# first, then in JAVA_HOME, then on PATH.
JAVAC="${JAVAC:-}"
if [ -z "$JAVAC" ]; then
	java_bin_dir="${JAVA:+$(dirname -- "$JAVA")}"
	for candidate in "${java_bin_dir:+$java_bin_dir/javac}" \
		"${JAVA_HOME:+$JAVA_HOME/bin/javac}" "$(command -v javac 2>/dev/null || true)"; do
		[ -n "$candidate" ] && [ -x "$candidate" ] && JAVAC="$candidate" && break
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

# Compile the Java checks once and run them by class name.
#
# These were run as `java -cp json.jar CheckExtraKeys.java`, which is
# single-file source-code mode. That mode leans on two launcher behaviours that
# differ between JDKs, and both bit this suite:
#
#   * Which class is run. JEP 330 picks the first top-level class with a main
#     method; with Macro in the same file, some JDKs chose Macro and failed with
#     "can't find main(String[]) method in class: Macro".
#   * Which sources are compiled. Source-file mode compiles the file named on
#     the command line and does not put its directory on the source path, so a
#     sibling Macro.java was invisible: the CI runner failed with "cannot find
#     symbol: class Macro", while the same command passed locally on JDK 25.
#
# A green local run was therefore not evidence about the runner. Compiling first
# and running a named class is explicit and behaves the same everywhere.
#
# Sets JAVA_CP and JAVA_STATUS, one of:
#   ok    compiled; JAVA_CP holds the classpath
#   skip  no usable toolchain on this host; the checks did not run
#   fail  the sources do not compile, which is a defect and not a skip
#
# The last case is the reason this function has three outcomes and not two. A
# missing javac is a host that cannot run the check; a source file that does not
# compile is a broken repo. Reporting the second as a skip let a suite with a
# deleted Macro.java exit 0, which is exactly the failure it was written to catch.
JAVA_CP=""
JAVA_STATUS=""
compile_java() {
	JAVA_CP=""
	if [ -z "$JAVA" ] || [ ! -x "$JAVA" ]; then
		JAVA_STATUS=skip
		printf '  SKIP  no java found (JAVA=%s)\n' "${JAVA:-unset}"
		return 0
	fi
	if [ -z "$JSON_JAR" ] || [ ! -f "$JSON_JAR" ]; then
		JAVA_STATUS=skip
		printf '  SKIP  org.json not found (JSON_JAR=%s)\n' "${JSON_JAR:-unset}"
		printf '        curl -sLo test/json.jar https://repo1.maven.org/maven2/org/json/json/20240303/json-20240303.jar\n'
		return 0
	fi
	if [ -z "$JAVAC" ] || [ ! -x "$JAVAC" ]; then
		JAVA_STATUS=skip
		printf '  SKIP  no javac found; a JRE alone cannot compile these checks\n'
		printf '        JAVA=/path/to/java JAVAC=/path/to/javac JSON_JAR=$PWD/test/json.jar %s\n' "$0"
		return 0
	fi
	local out
	out="$(mktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/gh-android-javac.$$")"
	mkdir -p "$out" || {
		JAVA_STATUS=fail
		printf '  FAIL  could not make a directory for the compiled checks\n'
		return 1
	}
	if ! "$JAVAC" -nowarn -cp "$JSON_JAR" -d "$out" \
		"$HERE/CheckExtraKeys.java" "$HERE/Macro.java" \
		"$HERE/CheckReadmeTables.java" 2>&1; then
		JAVA_STATUS=fail
		printf '  FAIL  javac could not compile the checks\n'
		rm -rf "$out"
		return 1
	fi
	JAVA_CP="$out:$JSON_JAR"
	JAVA_STATUS=ok
	return 0
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
# turns a skip into a confusing failure. compile_java does that check.
compile_java
case "$JAVA_STATUS" in
ok)
	ran=$((ran + 1))
	if ! "$JAVA" -cp "$JAVA_CP" CheckExtraKeys "$ROOT/termux/termux.properties"; then
		failed=$((failed + 1))
	fi
	;;
fail)
	ran=$((ran + 1))
	failed=$((failed + 1))
	;;
*)
	# Did not run. Counted as one skipped suite; the second Java check below
	# refers back to this rather than repeating the reason.
	ran=$((ran + 1))
	skipped=$((skipped + 1))
	;;
esac

# --- README key tables match the properties file ---------------------------
#
# The tables in README.md and the JSON in termux.properties are both written by
# hand. They did drift, with the README claiming popups the file did not have,
# which fails silently for a user who swipes up and gets nothing. This fails
# when they disagree again.

printf '\n=== README key tables\n'
case "$JAVA_STATUS" in
ok)
	ran=$((ran + 1))
	if ! "$JAVA" -cp "$JAVA_CP" CheckReadmeTables \
		"$ROOT/termux/termux.properties" "$ROOT/README.md"; then
		failed=$((failed + 1))
	fi
	;;
fail)
	ran=$((ran + 1))
	failed=$((failed + 1))
	;;
*)
	skipped=$((skipped + 1))
	printf '  SKIP  needs the compiled checks above, which were skipped\n'
	;;
esac

printf '\n===================================\n'
if [ "$failed" -eq 0 ]; then
	printf 'all suites passed (%d run, %d skipped)\n' "$ran" "$skipped"
	exit 0
fi
printf '%d suite(s) FAILED (%d run, %d skipped)\n' "$failed" "$ran" "$skipped"
exit 1
