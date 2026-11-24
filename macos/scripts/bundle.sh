#!/bin/bash
# Builds OMNIS.app from the Swift package.
#
#   macos/scripts/bundle.sh            -> macos/build/OMNIS.app
#
# The bundle records where this checkout's backend folder and your Python
# are, so the app can start the backend service on demand. Set OMNIS_PYTHON
# to choose a specific interpreter (3.11 or newer).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
package="$(dirname "$here")"
repo="$(dirname "$package")"
backend="$repo/backend"
app="$package/build/OMNIS.app"

python="${OMNIS_PYTHON:-$(command -v python3)}"
"$python" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' || {
    echo "error: $python is older than Python 3.11" >&2
    exit 1
}
python="$("$python" -c 'import sys; print(sys.executable)')"

swift build --package-path "$package" -c release --product OmnisApp
binary="$(swift build --package-path "$package" -c release --show-bin-path)/OmnisApp"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/OMNIS"
# The Dock icon and the menu-bar glyph, drawn by scripts/make-icon.swift.
cp "$package/Resources/AppIcon.icns" "$package/Resources/MenuIcon.png" "$package/Resources/MenuIcon@2x.png" "$app/Contents/Resources/"

plist="$app/Contents/Info.plist"
# plutil takes each value as its own argument, so paths with spaces are safe.
plutil -create xml1 "$plist"
add() { plutil -insert "$1" "-$2" "$3" "$plist"; }
add CFBundleName string OMNIS
add CFBundleDisplayName string OMNIS
add CFBundleIdentifier string local.omnis.app
add CFBundleExecutable string OMNIS
add CFBundleIconFile string AppIcon
add CFBundlePackageType string APPL
add CFBundleShortVersionString string 0.1.0
add CFBundleVersion string 1
add LSMinimumSystemVersion string 26.0
add NSHighResolutionCapable bool YES
add NSPrincipalClass string NSApplication
add OMNISBackendDirectory string "$backend"
add OMNISPythonPath string "$python"
# Optional: with Ollama present, questions are answered by local models.
ollama="${OMNIS_OLLAMA:-$(command -v ollama || true)}"
if [ -n "$ollama" ]; then add OMNISOllamaPath string "$ollama"; fi
# Optional: with Docker present, the local models can search the web.
claude="${OMNIS_CLAUDE:-$(command -v claude || true)}"
if [ -n "$claude" ]; then add OMNISClaudePath string "$claude"; fi

docker="${OMNIS_DOCKER:-$(command -v docker || true)}"
if [ -n "$docker" ]; then add OMNISDockerPath string "$docker"; fi
# The search service is reached over plain HTTP on this Mac's own loopback
# address. This permits that and nothing else.
plutil -insert NSAppTransportSecurity -json '{"NSAllowsLocalNetworking":true}' "$plist"
add NSRemindersFullAccessUsageDescription string "OMNIS reads your reminders to answer questions about them, and changes them only when you confirm a change."
add NSPhotoLibraryUsageDescription string "OMNIS looks through your photos when you ask it to, and shows Claude the ones you ask about. It never changes or deletes a photo."
add NSAppleEventsUsageDescription string "OMNIS controls playback in Spotify when you ask it to."
# Shown by macOS when OMNIS first asks to read the calendar.
add NSCalendarsFullAccessUsageDescription string "OMNIS reads your calendar to answer questions about your schedule, and changes it only when you confirm a change."

# Signing. macOS remembers permissions (calendar, reminders, controlling
# other apps) against an app's signature. With a signing identity that stays
# the same, a rebuilt OMNIS is still the same app and keeps its permissions.
# Without one, each build is signed "ad hoc", looks new to macOS, and is asked
# again. scripts/make-signing-identity.sh creates the identity, once.
identity_name="OMNIS Local Signing"
identity="$(security find-certificate -c "$identity_name" -Z 2>/dev/null | awk '/SHA-1 hash:/ {print $NF; exit}')"
signed=""
if [ -n "$identity" ]; then
    # The Messages reader: a separate small program, so that it and not OMNIS
    # holds the permission to read messages. Each recognises the other by this
    # Mac's signing identity, so it is built only when that identity exists.
    leaf="$(printf '%s' "$identity" | tr 'A-F' 'a-f')"
    reader="$package/build/OMNIS Messages Reader.app"
    swift build --package-path "$package" -c release --product OmnisMessagesReader
    rm -rf "$reader"
    mkdir -p "$reader/Contents/MacOS"
    cp "$(swift build --package-path "$package" -c release --show-bin-path)/OmnisMessagesReader" "$reader/Contents/MacOS/OMNIS Messages Reader"
    reader_plist="$reader/Contents/Info.plist"
    plutil -create xml1 "$reader_plist"
    radd() { plutil -insert "$1" "-$2" "$3" "$reader_plist"; }
    radd CFBundleName string "OMNIS Messages Reader"
    radd CFBundleIdentifier string local.omnis.messages-reader
    radd CFBundleExecutable string "OMNIS Messages Reader"
    radd CFBundlePackageType string APPL
    radd CFBundleShortVersionString string 0.1.0
    radd CFBundleVersion string 1
    radd LSMinimumSystemVersion string 26.0
    # No Dock icon and no window: it only answers OMNIS.
    radd LSUIElement bool YES
    # The only program it answers: OMNIS, signed with this identity.
    radd OMNISCallerRequirement string "identifier \"local.omnis.app\" and certificate leaf = H\"$leaf\""
    if perl -e 'alarm shift; exec @ARGV' 45 codesign --force --sign "$identity" --identifier local.omnis.messages-reader "$reader" >/dev/null 2>&1; then
        add OMNISMessagesReaderPath string "$reader"
        add OMNISMessagesReaderRequirement string "identifier \"local.omnis.messages-reader\" and certificate leaf = H\"$leaf\""
    else
        rm -rf "$reader"
    fi
    # The first use makes macOS ask whether codesign may use the key. If
    # nobody answers, give up after a while and fall back, so a build never hangs.
    if perl -e 'alarm shift; exec @ARGV' 45 codesign --force --sign "$identity" --identifier local.omnis.app "$app" >/dev/null 2>&1; then
        signed="with \"$identity_name\": permissions are kept across rebuilds"
    fi
fi
if [ -z "$signed" ]; then
    codesign --force --sign - "$app" >/dev/null 2>&1
    signed="ad hoc: macOS will ask for permissions again after each rebuild (see scripts/make-signing-identity.sh)"
fi

echo "Built $app"
echo "Signed $signed"
exit 0

echo "Built $app"
