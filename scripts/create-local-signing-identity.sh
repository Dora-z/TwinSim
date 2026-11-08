#!/bin/bash
# Creates a self-signed code-signing identity "TwinSim Local Signing" in your login keychain.
#
# Why: ad-hoc builds get a new code identity on every build, so macOS asks again for privacy
# permissions such as "access files on a removable volume". Builds signed with this identity keep
# the same designated requirement (bundle ID + certificate), so one approval survives rebuilds.
# scripts/package-app.sh uses it automatically when it exists.
#
# The certificate is not added to any trust settings and only signs code. It does not make the app
# notarized for other Macs. Undo: delete "TwinSim Local Signing" in Keychain Access.
set -euo pipefail
name=${TWINSIM_LOCAL_IDENTITY:-TwinSim Local Signing}
openssl=$(command -v openssl)
if security find-certificate -c "$name" >/dev/null 2>&1; then
    echo "Identity \"$name\" already exists."
    exit 0
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/twinsim-identity.XXXXXX")
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"
cat > "$work/req.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
"$openssl" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/req.cnf" \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
pass=$("$openssl" rand -hex 16)
# macOS `security import` only reads the legacy PKCS#12 algorithms.
"$openssl" pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 -passout "pass:$pass" -out "$work/id.p12"
security import "$work/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$pass" -T /usr/bin/codesign >/dev/null
echo "Created \"$name\" in the login keychain."
echo "Next: bash scripts/package-app.sh, then reinstall the app and approve the permission prompt once."
