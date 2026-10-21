#!/bin/sh
set -eu

if [ "$#" != 1 ] || [ -z "${P12_PASSWORD:-}" ]; then
    printf '%s\n' 'Usage: P12_PASSWORD=... Packaging/create-private-signing-certificate.sh OUTPUT_DIRECTORY' >&2
    exit 2
fi
umask 077
output="$1"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
for name in Acouplet-private-signing.p12 Acouplet-private-signing.pem; do
    if [ -e "$output/$name" ] || [ -L "$output/$name" ]; then
        printf '%s\n' 'The output already contains a signing certificate. Existing keys were preserved.' >&2
        exit 1
    fi
done
work="$(mktemp -d "$output/.certificate.XXXXXX")"
trap 'rm -rf "$work"' EXIT HUP INT TERM
cat > "$work/certificate.conf" <<'CONFIG'
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = Acouplet Private Releases
[extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG
/usr/bin/openssl req -new -newkey rsa:3072 -nodes -x509 -days 3650 \
    -config "$work/certificate.conf" -keyout "$work/private.pem" -out "$work/certificate.pem" 2> "$work/openssl.log"
/usr/bin/openssl pkcs12 -export -inkey "$work/private.pem" -in "$work/certificate.pem" \
    -name 'Acouplet Private Releases' -passout env:P12_PASSWORD -out "$output/Acouplet-private-signing.p12"
cp "$work/certificate.pem" "$output/Acouplet-private-signing.pem"
fingerprint="$(/usr/bin/openssl x509 -in "$work/certificate.pem" -noout -fingerprint -sha1 | /usr/bin/sed 's/.*=//;s/://g')"
printf 'Certificate SHA1: %s\nEncrypted identity: %s\nPublic certificate: %s\n' \
    "$fingerprint" "$output/Acouplet-private-signing.p12" "$output/Acouplet-private-signing.pem"
