#!/bin/bash
# Creates a signing identity for OMNIS on this Mac, once.
#
#   macos/scripts/make-signing-identity.sh
#
# macOS ties permissions such as calendar access to an app's signature. An
# identity that stays the same means a rebuilt OMNIS keeps its permissions.
#
# This makes a self-signed certificate called "OMNIS Local Signing" and puts
# it, with its private key, in your login keychain. It is good for signing
# things on this Mac and nothing else: no one else's Mac will trust it. The
# key is created in a temporary folder that is deleted at the end.
#
# To undo it: open Keychain Access, search for "OMNIS Local Signing", and
# delete the certificate and the key.
set -euo pipefail

name="OMNIS Local Signing"
if security find-certificate -c "$name" >/dev/null 2>&1; then
    echo "\"$name\" already exists. Nothing to do."
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat > "$work/request.cnf" <<CONFIG
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = $name
[extensions]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONFIG

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/request.cnf" \
    -keyout "$work/key.pem" -out "$work/certificate.pem" >/dev/null 2>&1
passphrase="$(openssl rand -hex 16)"
# The older settings here are the ones the macOS keychain can read.
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/certificate.pem" -name "$name" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -out "$work/identity.p12" -passout "pass:$passphrase" >/dev/null 2>&1
security import "$work/identity.p12" -P "$passphrase" -T /usr/bin/codesign >/dev/null

echo "Created \"$name\" in your login keychain."
echo "The first build after this makes macOS ask whether codesign may use the key."
echo "Choose Always Allow, so later builds are signed without asking."
