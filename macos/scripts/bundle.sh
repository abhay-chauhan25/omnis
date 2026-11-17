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

# Ad-hoc signature: enough to run on this Mac, not for distribution.
codesign --force --sign - "$app" >/dev/null 2>&1

echo "Built $app"
