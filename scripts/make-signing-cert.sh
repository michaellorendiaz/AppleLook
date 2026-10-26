#!/usr/bin/env bash
# One-time setup: create a self-signed code-signing certificate, "AppleLook Self-Signed",
# in your login keychain. build-app.sh signs with it when it exists.
#
# Why: an ad-hoc signed app is identified by an exact hash of its files, so macOS treats
# every new build as a different app and forgets its Calendar permission. Signing every
# build with the same certificate keeps the permission across updates. (A $99 Apple
# Developer ID would do this and also remove the Gatekeeper warning.)
#
# A backup of the certificate goes to ~/Documents/AppleLook-signing/. Keep it: building on
# another Mac, or after losing it, needs the same certificate to keep users' permissions.
# To undo: delete "AppleLook Self-Signed" in Keychain Access (login keychain).
set -euo pipefail

NAME="AppleLook Self-Signed"
OUT="$HOME/Documents/AppleLook-signing"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" is already in your keychain."
  exit 0
fi

mkdir -p "$OUT"
cd "$(mktemp -d)"
cat > cert.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = AppleLook Self-Signed
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null

PASSWORD="$(openssl rand -hex 16)"
# -legacy: macOS's keychain can't read the newer PKCS#12 encryption from OpenSSL 3
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -name "$NAME" \
  -out "$OUT/AppleLook-signing.p12" -passout "pass:$PASSWORD" 2>/dev/null ||
  openssl pkcs12 -export -inkey key.pem -in cert.pem -name "$NAME" \
    -out "$OUT/AppleLook-signing.p12" -passout "pass:$PASSWORD"
printf '%s\n' "$PASSWORD" > "$OUT/p12-password.txt"
chmod 600 "$OUT"/*
rm -f key.pem

# -T lets codesign use the key without a Keychain prompt on every build
security import "$OUT/AppleLook-signing.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$PASSWORD" -T /usr/bin/codesign
echo "Created \"$NAME\". Backup: $OUT"
