#!/bin/bash
# Makes a permanent, self-made code signing certificate for the Mac app, in its own keychain
# (~/Library/Keychains/cadence-signing.keychain-db, never the login keychain).
#
# Why: without one, Cadence is signed "ad hoc", so every build looks like a brand-new app to macOS, and the
# permissions you gave it (Accessibility for Firefox blocking, Automation for the other browsers) quietly stop
# applying after each rebuild. Signed with the same certificate every time, they stick.
#
# Run once. Builds pick it up through scripts/sign-mac.sh; without it they fall back to ad hoc signing.
set -euo pipefail
NAME="Cadence Local Signing"
KC="$HOME/Library/Keychains/cadence-signing.keychain-db"
DIR="$HOME/Library/Application Support/CadenceSigning"
if [ -f "$KC" ]; then echo "Already set up: $KC"; exit 0; fi
mkdir -p "$DIR"; chmod 700 "$DIR"
# The keychain's password only guards this one local certificate; it's kept next to it so builds can unlock it.
PW=$(openssl rand -hex 24); printf %s "$PW" > "$DIR/keychain-password"; chmod 600 "$DIR/keychain-password"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
P12PW=$(openssl rand -hex 12)
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" -passout "pass:$P12PW" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" -passout "pass:$P12PW"
# create-keychain adds the new keychain to your search list; put the list back as it was afterwards.
OLD_LIST=$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')
security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"            # no auto-lock
security unlock-keychain -p "$PW" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$P12PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
# shellcheck disable=SC2086
IFS=$'\n'; security list-keychains -d user -s $OLD_LIST; unset IFS
echo "Made \"$NAME\" in $KC"
openssl x509 -in "$TMP/cert.pem" -noout -fingerprint -sha1 | sed 's/^/  /'
