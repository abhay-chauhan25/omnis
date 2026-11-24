#!/bin/bash
# Moves OMNIS's signing key out of silent reach, once.
#
#   macos/scripts/protect-signing-key.sh        (run it yourself, in Terminal)
#
# Why: macOS gives permissions (calendar, reminders, photos, and for the
# Messages reader, Full Disk Access) to whatever carries OMNIS's signature.
# While the key sits in your login keychain and the signing tool may use it
# without asking, any program running as you could sign itself as OMNIS.
#
# What this does:
#   1. Makes a new keychain, "omnis-signing", with a password you choose.
#   2. Makes a NEW signing key in it. The old key has been within reach of
#      other programs, so it is replaced, not moved.
#   3. Deletes the old key from your login keychain.
#   4. Clears the permissions macOS holds for OMNIS, because they were given
#      to the old signature. macOS will ask again, once, for the calendar,
#      reminders, photos and controlling Spotify.
#
# Afterwards the keychain stays locked. `bundle.sh` unlocks it while it signs
# and locks it again, so you type the password when you build, and at no
# other time. If macOS ever asks for this password when you are not building
# OMNIS, say no.
#
# To undo: delete "omnis-signing" in Keychain Access, then run
# make-signing-identity.sh.
set -euo pipefail

name="OMNIS Local Signing"
keychain="$HOME/Library/Keychains/omnis-signing.keychain-db"
login="$HOME/Library/Keychains/login.keychain-db"

if [ ! -t 0 ]; then
    echo "error: run this yourself in Terminal; it has to ask you for a password" >&2
    exit 1
fi
if [ -f "$keychain" ]; then
    echo "The signing keychain already exists at $keychain. Nothing to do."
    exit 0
fi

echo "This replaces OMNIS's signing key with a new one kept in its own locked keychain."
echo "macOS will ask again for OMNIS's permissions the next time each is used."
printf "Go ahead? [y/N] "
read -r answer
case "$answer" in y|Y|yes|Yes) ;; *) echo "Nothing was changed."; exit 0 ;; esac

echo
echo "Choose a password for the new keychain. You will type it each time you build OMNIS."
/usr/bin/security create-keychain "$keychain"

work="$(mktemp -d)"
cleanup() {
    rm -rf "$work"
    /usr/bin/security lock-keychain "$keychain" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Locks when the Mac sleeps, and by itself after five minutes.
/usr/bin/security set-keychain-settings -l -u -t 300 "$keychain"

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
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/certificate.pem" -name "$name" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -out "$work/identity.p12" -passout "pass:$passphrase" >/dev/null 2>&1
/usr/bin/security import "$work/identity.p12" -k "$keychain" -P "$passphrase" -T /usr/bin/codesign >/dev/null

echo
echo "Enter the new keychain's password once more, to let the signing tool use the key while the keychain is unlocked."
/usr/bin/security set-key-partition-list -S apple-tool:,apple: -s "$keychain" >/dev/null

# The signing tool only looks in keychains on your list. The others on it are kept.
current=()
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#\"}"
    current+=("${line%\"}")
done < <(/usr/bin/security list-keychains -d user)
/usr/bin/security list-keychains -d user -s "${current[@]}" "$keychain"

# Prove the new key signs before the old one is removed.
fingerprint="$(/usr/bin/security find-certificate -c "$name" -Z "$keychain" | awk '/SHA-1 hash:/ {print $NF; exit}')"
cp /usr/bin/true "$work/trial"
if ! /usr/bin/codesign --force --keychain "$keychain" --sign "$fingerprint" "$work/trial" >/dev/null 2>&1; then
    echo "error: the new key could not sign. The old key has been left in place; delete \"omnis-signing\" in Keychain Access to start again." >&2
    exit 1
fi

if /usr/bin/security find-certificate -c "$name" "$login" >/dev/null 2>&1; then
    /usr/bin/security delete-identity -c "$name" "$login" >/dev/null 2>&1 \
        || echo "note: the old key could not be removed from your login keychain. Delete \"$name\" there in Keychain Access."
fi
# Permissions given to the old signature are withdrawn.
/usr/bin/tccutil reset All local.omnis.app >/dev/null 2>&1 || true
/usr/bin/tccutil reset All local.omnis.messages-reader >/dev/null 2>&1 || true

echo
echo "Done. The new key's fingerprint is $fingerprint."
echo "Now build OMNIS yourself:  macos/scripts/bundle.sh"
echo "It will ask for this password, and macOS will ask again for OMNIS's permissions as you use them."
