# gh for Android

GitHub CLI on a phone, running under Termux, with the keys a touchscreen
cannot type and the session handling Android will not give you for free.

Three pieces:

| Piece | What it is |
| --- | --- |
| `dist/gh-arm64`, `dist/gh-arm`, `dist/gh-amd64` | GitHub CLI v2.102.0, cross-compiled for Android |
| `bin/ghm` | runs gh inside a tmux session that survives Android killing the app |
| `termux/termux.properties` | extra keys and one-tap tmux command macros |

## Install

The binaries are not in this repository. CI builds them and attaches them to the
[releases page](https://github.com/talaria0101/gh-android/releases), because three
Android binaries are about 130MB and that belongs in release assets rather than in
git history.

Download the one for your device, then install:

```sh
# check what you have, and get the matching file
uname -m                    # aarch64 -> gh-arm64, armv7l -> gh-arm, x86_64 -> gh-amd64

pkg install git tmux
git clone https://github.com/talaria0101/gh-android
cd gh-android
mkdir -p dist
gh release download --repo talaria0101/gh-android --pattern gh-arm64 --dir dist
gh release download --repo talaria0101/gh-android --pattern SHA256SUMS --dir dist

bash install.sh
```

`install.sh` checks the checksum against `dist/SHA256SUMS` before installing. If
you skip the `SHA256SUMS` download it says so rather than pretending to verify.

All three binaries in a release were built by the workflow from the same commit,
with Go and the Android NDK versions pinned in
[`.github/workflows/build.yml`](.github/workflows/build.yml).

| `uname -m` | Installs | Built by CI with |
| --- | --- | --- |
| `aarch64`, `arm64` | `dist/gh-arm64` | Go only, no NDK |
| `armv7l`, `armv8l`, `armv6l`, `arm` | `dist/gh-arm` | Go + Android NDK |
| `x86_64`, `amd64` | `dist/gh-amd64` | Go + Android NDK |
| `i386`, `i686` | nothing | not a target; use `pkg install gh` |

`armv8l` is what a 32-bit userland reports on an ARMv8 CPU, so it selects the same
32-bit binary.

If `install.sh` cannot find your architecture's binary it prints the exact
`gh release download` command for your device, so you never have to work out which
file to fetch.

Options: `--no-keys` skips the two config files, `--force` overwrites existing
ones instead of leaving them alone, `--uninstall` removes `gh` and `ghm`.

`install.sh` refuses to run anywhere that is not a Termux prefix, checks its
own arch's line in `dist/SHA256SUMS` only, refuses to overwrite an existing
`gh`, refuses to touch an existing `~/.termux/termux.properties` or
`~/.tmux.conf` without `--force` (writing the new file alongside as `.new`
instead), and runs the installed binary's `--version` before reporting success.
That last check calls the binary by full path, so a working `gh` already on
`PATH` cannot satisfy it on the broken binary's behalf.

It puts `gh` and `ghm` in `$PREFIX/bin` and the two config files under
`$TERMUX_HOME` (which defaults to `$HOME`), and records the installed paths in
`$TERMUX_HOME/.gh-android-installed` so `--uninstall` removes exactly those.
Without that record `--uninstall` refuses, rather than delete a `gh` that
`pkg install gh` put there.

tmux reads `~/.tmux.conf` only when its server starts, so apply it to a session
that is already running:

```sh
tmux source-file ~/.tmux.conf
```

Then authenticate:

```sh
gh auth login
```

If the browser flow does not work on your ROM, use a token from
<https://github.com/settings/tokens>:

```sh
gh auth login --with-token < token.txt && rm token.txt
```

A token typed directly into the shell ends up in history and in any synced
dotfile. Delete the file afterwards.

## Building

arm64 builds anywhere with Go; nothing else is needed:

```sh
./build/build-gh.sh                        # gh v2.102.0, arm64
GH_VERSION=v2.103.0 ./build/build-gh.sh   # a different release
```

32-bit ARM and amd64 need an Android NDK, because Go cannot link them without
cgo. Download one from <https://developer.android.com/ndk/downloads>, unpack
it, and point `ANDROID_NDK_HOME` at the unpacked directory:

```sh
ANDROID_NDK_HOME=/path/to/android-ndk-r25c ./build/build-gh.sh --arch arm
ANDROID_NDK_HOME=/path/to/android-ndk-r25c ./build/build-gh.sh --arch arm,amd64
```

The script finds the right cross clang inside the NDK itself; you do not have to
name it. The API level defaults to 21 (Android 5.0), which is the oldest a
32-bit Termux supported:

```sh
ANDROID_NDK_HOME=... API=24 ./build/build-gh.sh --arch arm
```

These are the same commands CI runs, with the Go and NDK versions pinned in
[`.github/workflows/build.yml`](.github/workflows/build.yml).

### Why the extra toolchain

Not a choice this project made. Go's platform table
(`internal/platform/supported.go`, `MustLinkExternal`) forces external cgo
linking for every `android/*` arch except `arm64`, so with `CGO_ENABLED=0` the
others fail with:

```
android/arm requires external (cgo) linking, but cgo is not enabled
```

External cgo linking means a C compiler that targets Bionic, which means an
NDK. The `arm64` build is pure Go and links internally, which is why it needs
nothing.

### What the binaries look like

| Arch | ELF | Interpreter | Links libc |
| --- | --- | --- | --- |
| arm64 | 64-bit AArch64 PIE | `/system/bin/linker64` | no |
| arm | 32-bit ARM PIE | `/system/bin/linker` | yes |
| amd64 | 64-bit x86-64 PIE | `/system/bin/linker64` | yes |

The arm64 build is 100% Go and needs only the system linker. The two cgo
builds also link `libc.so`, `libdl.so` and `liblog.so`, which Android has
provided in its system partition on every release since 5.0.

### Building on the phone

On a 64-bit phone, `arm64` needs only the Go toolchain:

```sh
pkg install golang
./build/build-gh.sh
```

Cross-compiling arm or amd64 from a phone needs the NDK on the phone as well,
which is impractical. Build those elsewhere and copy them over, or use
`pkg install gh` on a 32-bit phone.

## Using it

`gh` works normally:

```sh
gh pr list
gh run watch
gh issue create --title "..."
```

Use `ghm` when the command is long enough that losing it would hurt. It puts gh
in a tmux session named after the current repo, so the command keeps running
while you switch apps or lock the screen:

```sh
ghm pr list                 # start (or reuse) this repo's session
ghm run watch               # a watch that survives switching apps
ghm ls                      # what sessions exist
ghm attach                  # come back to this repo's session
ghm wake                    # hold a wake lock so Android does not freeze the CPU
ghm kill                    # close this repo's session
ghm new <gh args...>        # start fresh, replacing this repo's session
```

`ghm new` kills the existing session first, so anything still running in it is
lost. `ghm` with no arguments prints usage rather than running `gh ''`.

Detach with the `tMX` key. Leave one session per repo open and they are all
still there tomorrow.

`ghm` does not do anything `tmux` does not: it derives a session name, creates
it if missing, sends the command into it if present, and attaches. Everything
else is ordinary tmux, so `prefix ?` inside a session lists the real bindings.

### Authenticating

gh resolves its config through `$HOME` (or `$XDG_CONFIG_HOME`), so it works on
Termux with no special setup. With cgo disabled, Go's `os/user` returns a dummy
record on Android instead of reading a passwd database, which gh does not
depend on.

## Key combos

Three rows of extra keys. Show them by long-pressing the keyboard button in the
Termux drawer. Swipe up on a key for its popup.

**Row 1** is what gh's own prompts need. `gh pr create`, `gh pr checkout` and
`gh issue create` are arrow-driven and cancel with Ctrl-C or Escape, so both
must be reachable without a hardware keyboard. CTRL and ALT are sticky
modifiers: tap one, then tap a letter.

| Key | Sends | Swipe up |
| --- | --- | --- |
| ESC | Escape | |
| CTRL | sticky modifier | |
| ALT | sticky modifier | |
| TAB | Tab | |
| BKSP | Backspace | DEL |
| ENTER | Enter | |
| LEFT | arrow left | HOME |
| DOWN | arrow down | PGDN |
| UP | arrow up | PGUP |
| RIGHT | arrow right | END |

**Row 2** is the characters gh commands need and Android keyboards hide. `|`
is the important one: without it `gh api ... \| jq` is not typable.

| Key | Sends | Swipe up |
| --- | --- | --- |
| \| | pipe | |
| ~ | tilde | |
| - | hyphen | |
| / | slash | |
| " | double quote | BACKSLASH |
| ' | apostrophe | backtick |
| $ | dollar | |
| * | star | |
| + | plus | = |

**Row 3** is tmux. Each is one tap that expands to a real key sequence.

| Key | Sends | tmux does | Swipe up |
| --- | --- | --- | --- |
| tMX | Ctrl-B d | detach, gh keeps running | Ctrl-B &, kill window (asks) |
| tMs | Ctrl-B % | split side by side | Ctrl-B ", stacked split |
| tMW | Ctrl-B c | new window | Ctrl-B n, next window |
| tMp | Ctrl-B p | previous window | Ctrl-B z, zoom |
| tM[ | Ctrl-B [ | copy mode, scroll gh output | Ctrl-B q, show panes |
| tM? | Ctrl-B ? | tmux's shortcut list | Ctrl-B t, clock |

The prefix is Ctrl-B, tmux's default. If you change it with
`tmux set -g prefix C-a`, update the macros in row 3 to match.

The back key is set to send Escape, so a mis-tap inside a gh prompt cancels it
instead of leaving the app.

## Files

```
build/build-gh.sh            cross-compiles gh for Android; arm64 needs only Go,
                             arm and amd64 need ANDROID_NDK_HOME
install.sh                   installs into a Termux prefix, with safety checks
bin/ghm                      tmux-backed gh wrapper
termux/termux.properties     extra keys and tmux macros
termux/tmux.conf             history, status bar, copy mode, split behaviour
.github/workflows/build.yml  builds the binaries; publishes a release on a tag
dist/                        where a downloaded binary goes; not committed
test/run-tests.sh            runs everything below
test/test-ghm.sh             the wrapper, against a recording tmux stand-in
test/test-install.sh         install.sh, against a fake Termux prefix
test/test-binary.sh          the built binaries, structurally and under qemu
test/CheckExtraKeys.java     validates extra-keys the way Termux reads it
test/CheckReadmeTables.java  checks the tables above against the JSON
test/DumpExtraKeys.java      prints the rows, for editing the tables above
test/json.jar                org.json, only for the two Java checks
```

## Tests

```sh
./test/run-tests.sh
```

Five suites: shell syntax, the `ghm` wrapper against a recording tmux
stand-in, an `install.sh` rehearsal against a fake prefix, the built binary,
and `tmux.conf`. Two more checks need a JDK and org.json:

```sh
curl -sLo test/json.jar https://repo1.maven.org/maven2/org/json/json/20240303/json-20240303.jar
./test/run-tests.sh
```

Without those, two checks skip and say so:

- **extra-keys** runs the shipped `termux.properties` through the same two
  libraries Termux uses, `java.util.Properties` and `org.json.JSONArray`, then
  starts a throwaway tmux server with `-f /dev/null`, that is stock defaults
  rather than `tmux.conf`, and requires every macro's command key to be one
  tmux binds after the prefix. A macro naming an unbound key fails.
- **README key tables** compares the tables in this file against the JSON,
  because both are written by hand and did drift once, with this file claiming
  popups the properties file did not have.

The binary check runs `linux/arm64` and `linux/arm` builds of the same source
under qemu, and inspects each shipped binary structurally: right machine type,
PIE, the correct Bionic interpreter, and `libc.so` present for the cgo-linked
arches but absent for arm64. It has been run against Go 1.27.1 with NDK r25c and
tmux 3.7c.

## What is not verified

The shipped binaries need Bionic's linker (`/system/bin/linker` or
`/system/bin/linker64`), so none of them can be executed off-device. The tests
check them structurally, and build `linux/arm64` and `linux/arm` siblings of the
same source to execute under `qemu-aarch64-static` and `qemu-arm-static`. That
proves the gh code, the version pin and the config handling work on both
architectures, and that the shipped artifacts are correctly shaped Android PIEs
pointing at the right Bionic linker. It does not prove Go's Android runtime
starts on a real Bionic device. Run `gh --version` on the phone to confirm that.

Two Termux-specific behaviours are read from the source rather than observed on
a device:

- a macro applies its modifier to one key only
  (`TerminalExtraKeys.onExtraKeyButtonClick`), which is why `CTRL b d` is two
  keys and not one;
- `java.util.Properties` unescapes backslashes before org.json parses the value,
  which is why the backslash key is written as the `BACKSLASH` alias. A literal
  `\\` in the file makes the whole extra-keys row silently revert to the
  default.

## Notes on Termux quirks found while building this

- One `extra-keys` line only. `java.util.Properties` keeps the last value for a
  repeated key, so three `extra-keys` lines would leave one row.
- `terminal-transcript-rows` defaults to 2000, with a maximum of 50000
  (`TerminalEmulator.TERMINAL_TRANSCRIPT_ROWS_MAX`). The config sets 10000.
- `terminal-transcript-rows = 2000` looks like a setting and is not: it is
  already the default.

## Licence

gh is MIT, © GitHub Inc. The scripts here are MIT. Termux is GPL-3.0 and is not
included; only its configuration format is used.
