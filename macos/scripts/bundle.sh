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
mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/OMNIS"

plist="$app/Contents/Info.plist"
# plutil takes each value as its own argument, so paths with spaces are safe.
plutil -create xml1 "$plist"
add() { plutil -insert "$1" "-$2" "$3" "$plist"; }
add CFBundleName string OMNIS
add CFBundleDisplayName string OMNIS
add CFBundleIdentifier string local.omnis.app
add CFBundleExecutable string OMNIS
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
# Shown by macOS when OMNIS first asks to read the calendar.
add NSCalendarsFullAccessUsageDescription string "OMNIS reads your calendar to answer questions about your schedule, and changes it only when you confirm a change."

# Ad-hoc signature: enough to run on this Mac, not for distribution.
codesign --force --sign - "$app" >/dev/null 2>&1

echo "Built $app"
