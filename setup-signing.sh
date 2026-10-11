#!/usr/bin/env bash
# One-time setup: creates a local code-signing certificate ("Reel Local Signing") in your
# login keychain so every rebuild of Reel has the same signature. That lets macOS remember
# the Screen Recording permission instead of asking again after each build.
# Then clears Reel's stale permission entries, rebuilds and relaunches it.
set -uo pipefail
cd "$(dirname "$0")"

NAME="Reel Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "→ \"$NAME\" certificate already exists"
else
  echo "→ Creating \"$NAME\" certificate"
  TMP="$(mktemp -d)"
  cat > "$TMP/cert.cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CFG
  # Apple's bundled LibreSSL writes a .p12 that `security import` understands.
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cfg"
  /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/identity.p12" -passout pass:reel
  security import "$TMP/identity.p12" -k "$KEYCHAIN" -P reel -T /usr/bin/codesign
  rm -rf "$TMP"
fi

echo "→ Quitting Reel and clearing its old permission entries"
pkill -x Reel 2>/dev/null || true
tccutil reset ScreenCapture com.joebentaylor.reel || true
tccutil reset Microphone com.joebentaylor.reel || true

bash build.sh install
