#!/usr/bin/env bash
# One-time setup: creates a local code-signing certificate ("Oneshot Local Signing") in your
# login keychain so every rebuild of Oneshot has the same signature. That lets macOS remember
# the Screen Recording permission instead of asking again after each build.
# Then clears Oneshot's stale permission entries, rebuilds and relaunches it.
set -uo pipefail
cd "$(dirname "$0")"

NAME="Oneshot Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1 \
   || security find-certificate -c "Reel Local Signing" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "→ Local signing certificate already exists"
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
    -name "$NAME" -out "$TMP/identity.p12" -passout pass:oneshot
  security import "$TMP/identity.p12" -k "$KEYCHAIN" -P oneshot -T /usr/bin/codesign
  rm -rf "$TMP"
fi

echo "→ Quitting Oneshot and clearing its old permission entries"
pkill -x Oneshot 2>/dev/null || true
for BUNDLE in com.joebentaylor.oneshot com.joebentaylor.reel; do
  tccutil reset ScreenCapture "$BUNDLE" || true
  tccutil reset Microphone "$BUNDLE" || true
done

bash build.sh install
