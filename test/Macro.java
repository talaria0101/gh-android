/**
 * A macro as written in termux.properties, plus the tmux key it expands to.
 *
 * Kept in its own file, not nested above the main class, because this suite is
 * run with `java CheckExtraKeys.java`, which is single-file source-code mode. In
 * that mode the launcher decides which class to run by looking for main, and a
 * second top-level class in the same file made it pick the wrong one on some JDKs:
 * it failed with "can't find main(String[]) method in class: Macro".
 */
class Macro {
	final String spec;
	final String commandKey;

	Macro(String spec, String commandKey) {
		this.spec = spec;
		this.commandKey = commandKey;
	}
}
