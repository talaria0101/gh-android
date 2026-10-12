import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.Reader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Iterator;
import java.util.List;
import java.util.Properties;
import java.util.Set;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Validates termux/termux.properties the way Termux itself reads it.
 *
 * Termux loads the file with java.util.Properties and then feeds the
 * extra-keys value to org.json.JSONArray (termux-app ExtraKeysInfo). Both
 * libraries are used here, so a value that passes is one Termux will accept.
 * That matters because a malformed value fails quietly: Termux logs the parse
 * error and silently reverts to its default key row, which looks to a user
 * exactly like "my key combos did nothing".
 *
 * Usage: java -cp json.jar CheckExtraKeys.java ../termux/termux.properties
 */
public class CheckExtraKeys {

	/** Fields ExtraKeysInfo / ExtraKeyButton understand. Anything else is junk. */
	private static final Set<String> ALLOWED = new HashSet<>(
			Arrays.asList("key", "macro", "display", "popup"));

	private static final List<String> ERRORS = new ArrayList<>();
	private static final List<Macro> MACROS = new ArrayList<>();
	private static int macroCount = 0;

	/**
	 * Modifier names Termux consumes in a macro without sending. Anything else in
	 * a macro is a key that gets sent to the terminal.
	 */
	private static final Set<String> MODIFIERS = new HashSet<>(
			Arrays.asList("CTRL", "ALT", "SHIFT", "FN", "CONTROL", "SHFT"));

	public static void main(String[] args) throws IOException, InterruptedException {
		Path props = Paths.get(args.length > 0 ? args[0] : "../termux/termux.properties");

		Properties properties = new Properties();
		try (Reader reader = Files.newBufferedReader(props, StandardCharsets.UTF_8)) {
			properties.load(reader);
		}

		String raw = properties.getProperty("extra-keys");
		if (raw == null) {
			System.out.println("FAIL: no extra-keys property in " + props);
			System.exit(1);
		}

		System.out.println("properties keys: " + properties.stringPropertyNames());

		JSONArray rows;
		try {
			rows = new JSONArray(raw);
		} catch (JSONException e) {
			System.out.println("FAIL: extra-keys is not valid JSON per org.json: " + e.getMessage());
			System.exit(1);
			return;
		}

		if (rows.length() == 0) {
			System.out.println("FAIL: extra-keys has no rows");
			System.exit(1);
		}

		int[] widths = new int[rows.length()];
		for (int i = 0; i < rows.length(); i++) {
			Object rowObject = rows.opt(i);
			if (!(rowObject instanceof JSONArray)) {
				ERRORS.add("row " + i + ": is not an array");
				continue;
			}
			JSONArray row = (JSONArray) rowObject;
			widths[i] = row.length();
			if (row.length() == 0) {
				ERRORS.add("row " + i + ": is empty");
			}
			for (int j = 0; j < row.length(); j++) {
				checkEntry(row.opt(j), "row " + i + " key " + j);
			}
		}

		for (String error : ERRORS) {
			System.out.println("FAIL: " + error);
		}
		if (!ERRORS.isEmpty()) {
			System.exit(1);
		}

		System.out.println("extra-keys OK: " + rows.length() + " rows, widths " + Arrays.toString(widths));
		System.out.println("macros defined: " + macroCount);

		// Every macro must name a command key the running tmux actually binds in
		// its prefix table. Otherwise the key does nothing on the phone, which is
		// the failure mode hardest to diagnose from a screenshot.
		checkTmuxBindings();

		// Checked last, because checkTmuxBindings appends to ERRORS. Reporting
		// these before exiting is what makes the exit code meaningful.
		for (String error : ERRORS) {
			System.out.println("FAIL: " + error);
		}
		if (!ERRORS.isEmpty()) {
			System.exit(1);
		}
		System.out.println("all checks passed");
	}

	/**
	 * Ask tmux which keys it binds in the prefix table, and require every macro's
	 * command key to be among them.
	 */
	private static void checkTmuxBindings() throws IOException, InterruptedException {
		String version = run(new String[] {"tmux", "-V"}).trim();
		if (version.isEmpty()) {
			System.out.println("SKIP: tmux not available, cannot check bindings");
			return;
		}
		System.out.println("checking macros against " + version);

		List<String> bound = new ArrayList<>();
		Process process = new ProcessBuilder("tmux", "-f", "/dev/null", "-L", "ghm-keycheck",
				"start-server", ";", "list-keys", "-T", "prefix").redirectErrorStream(true).start();
		try (BufferedReader reader = new BufferedReader(
				new InputStreamReader(process.getInputStream(), StandardCharsets.UTF_8))) {
			String line;
			while ((line = reader.readLine()) != null) {
				// "bind-key -T prefix %  split-window -h", or a long display-menu
				// entry whose command field is many words. Only the key is needed.
				String[] fields = line.trim().split("\\s+");
				if (fields.length < 4 || !fields[0].equals("bind-key")) {
					continue;
				}
				if (!fields[1].equals("-T") || !fields[2].equals("prefix")) {
					continue;
				}
				bound.add(fields[3]);
			}
		}
		process.waitFor();
		run(new String[] {"tmux", "-f", "/dev/null", "-L", "ghm-keycheck", "kill-server"});

		if (bound.isEmpty()) {
			System.out.println("SKIP: tmux returned no prefix bindings to check against");
			return;
		}

		int unknown = 0;
		for (Macro macro : MACROS) {
			String key = macro.commandKey;
			// tmux prints a literal quote and percent escaped in its key table.
			if (bound.contains(key) || bound.contains("\\" + key)) {
				System.out.println("  OK  " + macro.spec + " -> prefix " + key);
			} else {
				unknown++;
				System.out.println("FAIL: macro '" + macro.spec + "' sends '" + key
						+ "', which tmux does not bind after the prefix");
			}
		}
		if (unknown > 0) {
			ERRORS.add(unknown + " macro(s) name a key tmux does not bind");
		}
	}

	private static String run(String[] command) throws IOException, InterruptedException {
		Process process;
		try {
			process = new ProcessBuilder(command).redirectErrorStream(true).start();
		} catch (IOException e) {
			return "";
		}
		StringBuilder out = new StringBuilder();
		try (BufferedReader reader = new BufferedReader(
				new InputStreamReader(process.getInputStream(), StandardCharsets.UTF_8))) {
			String line;
			while ((line = reader.readLine()) != null) {
				out.append(line).append('\n');
			}
		}
		process.waitFor();
		return out.toString();
	}

	private static void checkEntry(Object entry, String where) {
		if (entry instanceof String) {
			if (((String) entry).isEmpty()) {
				ERRORS.add(where + ": empty string key");
			}
			return;
		}
		if (!(entry instanceof JSONObject)) {
			ERRORS.add(where + ": must be a string or object, got " + entry);
			return;
		}

		JSONObject object = (JSONObject) entry;
		Iterator<String> fields = object.keys();
		while (fields.hasNext()) {
			String field = fields.next();
			if (!ALLOWED.contains(field)) {
				ERRORS.add(where + ": unknown field '" + field + "'");
			}
		}

		if (!object.has("key") && !object.has("macro")) {
			ERRORS.add(where + ": object has neither 'key' nor 'macro'");
		}
		if (object.has("macro")) {
			macroCount++;
			String spec = String.valueOf(object.opt("macro"));
			System.out.println("  macro: " + spec);
			String command = lastKey(spec);
			if (command == null) {
				ERRORS.add("macro '" + spec + "' has no key to send");
			} else {
				MACROS.add(new Macro(spec, command));
			}
		}
		if (object.has("popup")) {
			checkEntry(object.opt("popup"), where + ".popup");
		}
	}

	/**
	 * Return the last non-modifier token of a macro, which is the key tmux sees
	 * after the prefix.
	 */
	private static String lastKey(String spec) {
		String found = null;
		for (String token : spec.split(" ")) {
			if (token.isEmpty()) {
				continue;
			}
			if (MODIFIERS.contains(token)) {
				continue;
			}
			found = token;
		}
		return found;
	}
}
