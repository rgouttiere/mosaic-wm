#!/bin/bash
# Creates a stable self-signed code-signing identity for Mosaic dev builds.
# Why: ad-hoc signatures (`codesign -s -`) change every rebuild, so macOS revokes
# the Accessibility grant and re-prompts each launch. A stable identity makes the
# grant persist across rebuilds — grant it once, never again.
#
# Reversible: delete the cert anytime with
#   security delete-certificate -c "Mosaic Self-Signed" ~/Library/Keychains/login.keychain-db
set -euo pipefail

CERT_NAME="Mosaic Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Identity '$CERT_NAME' already exists — nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CERT_NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/cert.cnf"

# -legacy: use SHA1/3DES so Apple's `security` (LibreSSL) can read the PKCS12.
# OpenSSL 3's default SHA256 MAC fails import with "MAC verification failed".
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -passout pass:mosaic -name "$CERT_NAME"

security import "$TMP/cert.p12" -k "$KEYCHAIN" -P mosaic -T /usr/bin/codesign

echo "Created code-signing identity '$CERT_NAME'."
echo "The first 'make bundle' may show a one-time keychain prompt — click 'Always Allow'."
