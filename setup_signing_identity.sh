#!/bin/bash
# One-time setup: create a self-signed code-signing identity whose signature
# stays STABLE across rebuilds, so macOS TCC (Accessibility / Input Monitoring /
# Microphone) grants survive `./build.sh`. Ad-hoc signing ("-") mints a new
# CDHash on every build and orphans the old grant (toggle on, app still denied).
set -euo pipefail

ID_NAME="${NOTCHWHISPER_IDENTITY:-NotchWhisper Dev}"
TMP="$(mktemp -d)"
KEY="$TMP/$ID_NAME.key"
CERT="$TMP/$ID_NAME.cert"
P12="$TMP/$ID_NAME.p12"
PASS="notchwhisper-import"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$ID_NAME\""; then
  echo "✓ identity '$ID_NAME' already exists — nothing to do"
  security find-identity -v -p codesigning | grep "$ID_NAME"
  exit 0
fi

echo "==> Generating self-signed code-signing cert '$ID_NAME' (10 years)"
cat > "$TMP/openssl.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $ID_NAME
O = Behkha
C = US
[v3_req]
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = critical, CA:false
CNF

openssl req -new -newkey rsa:2048 -nodes \
  -keyout "$KEY" -out "$TMP/$ID_NAME.csr" \
  -config "$TMP/openssl.cnf" >/dev/null 2>&1

openssl x509 -req -in "$TMP/$ID_NAME.csr" -signkey "$KEY" \
  -out "$CERT" -days 3650 -set_serial 0x4E574431 \
  -extfile "$TMP/openssl.cnf" -extensions v3_req >/dev/null 2>&1

openssl pkcs12 -export -out "$P12" -inkey "$KEY" -in "$CERT" \
  -passout "pass:$PASS" >/dev/null 2>&1

echo "==> Importing into login keychain (trust + codesign access)"
security import "$P12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$PASS" -T /usr/bin/codesign >/dev/null

# Trust the cert for code signing (user domain — no sudo needed)
security add-trusted-cert -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" "$CERT"

echo "==> Verifying"
security find-identity -v -p codesigning | grep "$ID_NAME" \
  || { echo "!! identity not found after import"; exit 1; }

echo
echo "✓ Done. build.sh will now sign with '$ID_NAME'."
echo "  Note: the FIRST codesign run may pop a keychain prompt — click 'Always Allow'."
