#!/bin/bash
# Sets up OMNIS's own voice and its second check on the wake phrase.
#
#   backend/scripts/setup-speech.sh
#
# It makes a Python environment and downloads two models into
# ~/Library/Application Support/OMNIS/speech (about 800 MB in all):
#
#   Kokoro 82M        the speaking voice        Apache 2.0
#   Whisper base.en   hears the wake phrase     MIT
#
# Everything is fetched once, checked against a known fingerprint, and then
# used with no network at all. Run it again at any time; what is already there
# and correct is kept.
set -euo pipefail

home="${OMNIS_SPEECH_HOME:-$HOME/Library/Application Support/OMNIS/speech}"
venv="$home/venv"
models="$home/models"
mkdir -p "$models"
chmod 700 "$home"

if [ ! -x "$venv/bin/python" ]; then
    if command -v uv >/dev/null 2>&1; then
        uv venv --quiet --python 3.12 "$venv"
    else
        python3 -m venv "$venv"
    fi
fi
# Exact versions: the ones this was tested with.
packages=(kokoro-onnx==0.6.1 faster-whisper==1.2.1 onnxruntime==1.32.0 ctranslate2==4.9.1)
if command -v uv >/dev/null 2>&1; then
    uv pip install --quiet --python "$venv/bin/python" "${packages[@]}"
else
    "$venv/bin/python" -m pip install --quiet "${packages[@]}"
fi

# name, where from, fingerprint (SHA-256)
fetch() {
    local target="$models/$1"
    if [ -f "$target" ] && [ "$(shasum -a 256 "$target" | cut -d' ' -f1)" = "$3" ]; then return; fi
    mkdir -p "$(dirname "$target")"
    echo "Downloading $1"
    curl -sSL --fail -o "$target.part" "$2"
    if [ "$(shasum -a 256 "$target.part" | cut -d' ' -f1)" != "$3" ]; then
        rm -f "$target.part"
        echo "error: $1 did not match its fingerprint and was not kept" >&2
        exit 1
    fi
    mv "$target.part" "$target"
}

kokoro="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
whisper="https://huggingface.co/Systran/faster-whisper-base.en/resolve/3d3d5dee26484f91867d81cb899cfcf72b96be6c"
fetch kokoro-v1.0.onnx "$kokoro/kokoro-v1.0.onnx" 7d5df8ecf7d4b1878015a32686053fd0eebe2bc377234608764cc0ef3636a6c5
fetch voices-v1.0.bin "$kokoro/voices-v1.0.bin" bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d
fetch whisper-base.en/model.bin "$whisper/model.bin" 2a166925539a16005f14ff328359f9b9adb9dc4fb631bb3b227526862e93e2ef
fetch whisper-base.en/config.json "$whisper/config.json" f3bc3821e9fc76a27bae538e11ae5b677dcdd352b4600429ce7951d398569aeb
fetch whisper-base.en/tokenizer.json "$whisper/tokenizer.json" 929c5252409436dce1b38a75d1abbcb5e132d170d8e324e4e04ed915fa2d22df
fetch whisper-base.en/vocabulary.txt "$whisper/vocabulary.txt" ff77588746d3a2595d32ab5b69ffd7b95ce2441ac57533cb66fc3eb575a115cf

echo "Speech is set up in $home"
