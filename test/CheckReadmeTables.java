import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.Reader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.Properties;

/**
 * Check README.md's key tables against termux/termux.properties.
 *
 * Both files are written by hand and drift. When they did, the README claimed
 * popups the properties file did not have, which is the worst kind of wrong
 * documentation: a user swipes up, nothing happens, and the README said it
 * would.
 *
 * The tables are read back out of README.md and compared against the JSON as
 * Termux itself parses it, with org.json. Formatting differences in the
 * markdown are normalised, so this compares meaning rather than bytes.
 *
 * Usage: java -cp json.jar CheckReadmeTables.java ../termux/termux.properties ../README.md
 */
public class CheckReadmeTables {

	private static final List<String> ERRORS = new ArrayList<>();

	/**
	 * Termux key aliases that render as something else on screen. The properties
	 * file names the alias; the README documents what the user sees. Both forms
	 * are accepted, so a table may say "backslash" or "BACKSLASH".
	 */
	private static final java.util.Map<String, String> ALIAS_NAMES = java.util.Map.of(
			"BACKSLASH", "backslash");

	public static void main(String[] args) throws Exception {
		Properties properties = new Properties();
		try (Reader reader = Files.newBufferedReader(Paths.get(args[0]), StandardCharsets.UTF_8)) {
			properties.load(reader);
		}
		JSONArray rows = new JSONArray(properties.getProperty("extra-keys"));

		List<String> readme = Files.readAllLines(Paths.get(args[1]), StandardCharsets.UTF_8);

		// Rows 1 and 2 are plain markdown tables: a header row, a separator, then
		// one row per key. Row 3 (the tmux macros) is checked by a different rule
		// below, since its cells contain a description rather than a popup.
		checkKeyTable(readme, rows, 0, "Row 1");
		checkKeyTable(readme, rows, 1, "Row 2");
		checkMacroTable(readme, rows.getJSONArray(2));

		for (String error : ERRORS) {
			System.out.println("FAIL: " + error);
		}
		if (!ERRORS.isEmpty()) {
			System.exit(1);
		}
		System.out.println("README key tables match termux.properties");
	}

	/**
	 * Compare one markdown table against one extra-keys row.
	 *
	 * A table row looks like: | ESC | Escape | |
	 * Cells are stripped of markdown emphasis and surrounding whitespace, and an
	 * empty cell means "no popup".
	 */
	private static void checkKeyTable(List<String> readme, JSONArray rows, int rowIndex, String label) {
		List<String> table = extractTable(readme);
		JSONArray row = rows.getJSONArray(rowIndex);

		// Find the separator row (| --- | --- |) that ends this table's header,
		// starting the search after the prose that introduces the table. Using the
		// separator rather than the preceding prose line is what keeps a wrapped
		// sentence containing "|" from being mistaken for the header.
		int header = tableSeparatorAfter(table, label);
		if (header < 0) {
			ERRORS.add("README has no table for " + label);
			return;
		}

		int rowsChecked = 0;
		int line = header + 1;
		for (int j = 0; j < row.length(); j++, line++) {
			Object entry = row.opt(j);
			if (line >= table.size()) {
				ERRORS.add(label + ": README table ends early, expected " + row.length() + " rows");
				return;
			}

			List<String> cells = splitCells(table.get(line));
			String wantKey = keyOf(entry);
			String wantPopup = popupOf(entry);

			String gotKey = cells.size() > 0 ? cells.get(0) : "";
			String gotPopup = cells.size() > 2 ? normalisePopup(cells.get(2)) : "";

			if (!wantKey.equals(gotKey)) {
				ERRORS.add(label + " row " + (j + 1) + ": README says key '" + gotKey
						+ "' but the properties file has '" + wantKey + "'");
			}
			if (!wantPopup.equals(gotPopup)) {
				ERRORS.add(label + " row " + (j + 1) + " ('" + wantKey + "'): README says popup '"
						+ gotPopup + "' but the properties file has '" + wantPopup + "'");
			}
			rowsChecked++;
		}
		if (rowsChecked != row.length()) {
			ERRORS.add(label + ": checked " + rowsChecked + " of " + row.length() + " keys");
		}
	}

	/**
	 * Check the tmux macro table: every macro in row 3 must appear in the README,
	 * and every README entry for row 3 must exist in the properties file.
	 */
	private static void checkMacroTable(List<String> readme, JSONArray row) {
		List<String> table = extractTable(readme);
		int header = tableSeparatorAfter(table, "Row 3");
		if (header < 0) {
			ERRORS.add("README has no table for Row 3");
			return;
		}

		List<String> readmeMacros = new ArrayList<>();
		for (int i = header + 1; i < table.size(); i++) {
			String line = table.get(i);
			if (!line.startsWith("|")) {
				break;
			}
			List<String> cells = splitCells(line);
			if (!cells.isEmpty() && !cells.get(0).isEmpty()) {
				readmeMacros.add(cells.get(0));
			}
		}

		List<String> fileMacros = new ArrayList<>();
		for (int i = 0; i < row.length(); i++) {
			JSONObject object = row.getJSONObject(i);
			fileMacros.add(String.valueOf(object.optString("display", "")));
		}

		for (String display : fileMacros) {
			if (!readmeMacros.contains(display)) {
				ERRORS.add("Row 3: '" + display + "' is in termux.properties but not in the README table");
			}
		}
		for (String display : readmeMacros) {
			if (!fileMacros.contains(display)) {
				ERRORS.add("Row 3: '" + display + "' is in the README table but not in termux.properties");
			}
		}
		System.out.println("Row 3: compared " + fileMacros.size() + " macro labels");
	}

	/**
	 * Return the contiguous block of markdown table lines that contains all three
	 * key sections, so tableIndexOf can find a section by its heading.
	 */
	private static List<String> extractTable(List<String> readme) {
		List<String> table = new ArrayList<>();
		boolean inTable = false;
		for (String line : readme) {
			if (line.startsWith("|")) {
				inTable = true;
				table.add(line);
			} else if (inTable) {
				// A blank line ends the table only if the next lines are not a
				// table either; keep collecting and let the headings separate.
				table.add(line);
			}
		}
		return table;
	}

	/**
	 * Find the header separator row (| --- | --- |) of the table introduced by the
	 * given label. Returns its index, or -1.
	 */
	private static int tableSeparatorAfter(List<String> table, String label) {
		for (int i = 0; i < table.size(); i++) {
			if (!table.get(i).contains(label)) {
				continue;
			}
			// The label is prose introducing the table, so scan forward to the
			// first separator rather than a fixed distance.
			for (int j = i + 1; j < table.size(); j++) {
				if (isSeparator(table.get(j))) {
					return j;
				}
				if (table.get(j).startsWith("|") && !isSeparator(table.get(j))) {
					// Reached table rows without a separator: the label matched a
					// cell rather than the prose, so keep looking for a separator.
					continue;
				}
			}
			return -1;
		}
		return -1;
	}

	/** True for a markdown table header separator such as "| --- | --- |". */
	private static boolean isSeparator(String line) {
		if (!line.startsWith("|")) {
			return false;
		}
		String body = line.substring(1).replace("|", "");
		return body.replace("-", "").replace(" ", "").isEmpty() && body.contains("-");
	}

	private static String keyOf(Object entry) {
		if (entry instanceof String) {
			return (String) entry;
		}
		JSONObject object = (JSONObject) entry;
		if (object.has("key")) {
			return String.valueOf(object.opt("key"));
		}
		// A macro key's display label, e.g. tMX.
		return String.valueOf(object.optString("display", ""));
	}

	private static String popupOf(Object entry) {
		if (entry instanceof String) {
			return "";
		}
		JSONObject object = (JSONObject) entry;
		Object popup = object.opt("popup");
		if (popup == null) {
			return "";
		}
		if (popup instanceof JSONObject) {
			// The popup is itself a macro; name it by what it displays.
			return String.valueOf(((JSONObject) popup).optString("display", ""));
		}
		return normalisePopup(String.valueOf(popup));
	}

	/** Characters the README may name in prose where the file uses a symbol. */
	private static final java.util.Map<String, String> CHARACTER_NAMES = java.util.Map.of(
			"`", "backtick",
			"\\", "backslash",
			"'", "apostrophe",
			"\"", "double quote");

	/** Normalise a popup cell for comparison against the properties file. */
	private static String normalisePopup(String value) {
		if (value.isEmpty()) {
			return "";
		}
		String alias = ALIAS_NAMES.get(value);
		if (alias != null) {
			return alias;
		}
		String named = CHARACTER_NAMES.get(value);
		if (named != null) {
			return named;
		}
		String readable = ALIAS_NAMES.get(value.toUpperCase(java.util.Locale.ROOT));
		return readable != null ? readable : value;
	}

	/** Split a markdown table row into trimmed cells, dropping the outer pipes. */
	private static List<String> splitCells(String row) {
		List<String> cells = new ArrayList<>();
		String body = row.trim();
		if (body.startsWith("|")) {
			body = body.substring(1);
		}
		if (body.endsWith("|")) {
			body = body.substring(0, body.length() - 1);
		}
		// Split on unescaped pipes only. A cell holding a pipe character has to be
		// written \| in markdown, and splitting naively turns "| \| | pipe |" into
		// three cells instead of two.
		StringBuilder current = new StringBuilder();
		for (int i = 0; i < body.length(); i++) {
			char c = body.charAt(i);
			if (c == '\\' && i + 1 < body.length() && body.charAt(i + 1) == '|') {
				// A pipe character, not a cell boundary. Keep it without the escape.
				current.append('|');
				i++;
				continue;
			}
			if (c == '|') {
				cells.add(current.toString().trim().replace("`", ""));
				current.setLength(0);
				continue;
			}
			current.append(c);
		}
		cells.add(current.toString().trim().replace("`", ""));
		return cells;
	}
}
