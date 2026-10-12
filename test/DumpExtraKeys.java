import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.Reader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Iterator;
import java.util.Properties;

/**
 * Print the extra-keys rows exactly as Termux will read them.
 *
 * Used to keep README.md's key tables honest. The tables are written by hand and
 * the JSON is written by hand, and the two drift; this prints the truth from
 * the same parser Termux uses, so the tables can be checked against it.
 *
 * Usage: java -cp json.jar DumpExtraKeys.java ../termux/termux.properties
 */
public class DumpExtraKeys {
	public static void main(String[] args) throws Exception {
		Properties properties = new Properties();
		try (Reader reader = Files.newBufferedReader(Paths.get(args[0]), StandardCharsets.UTF_8)) {
			properties.load(reader);
		}

		JSONArray rows = new JSONArray(properties.getProperty("extra-keys"));
		for (int i = 0; i < rows.length(); i++) {
			JSONArray row = rows.getJSONArray(i);
			System.out.println("row " + (i + 1) + " (" + row.length() + " keys)");
			for (int j = 0; j < row.length(); j++) {
				Object entry = row.opt(j);
				if (entry instanceof String) {
					System.out.println("  " + describe((String) entry));
				} else {
					JSONObject object = (JSONObject) entry;
					StringBuilder line = new StringBuilder("  object ");
					Iterator<String> fields = object.keys();
					boolean first = true;
					while (fields.hasNext()) {
						String field = fields.next();
						if (!first) {
							line.append(' ');
						}
						line.append(field).append('=').append(object.opt(field));
						first = false;
					}
					System.out.println(line);
				}
			}
		}
	}

	private static String describe(String key) {
		return "string '" + key + "'";
	}
}
