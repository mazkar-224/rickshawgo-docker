#!/usr/bin/env bash
# make-cert.sh - issue a TLS certificate for the lab domain from a small private CA
#
# Usage: ./scripts/make-cert.sh CA_DIR OUT_DIR [DOMAIN...]
#   CA_DIR   where the lab CA lives (created on the first run). Keep it OUT of the repository:
#            ca.key can sign certificates for any name.
#   OUT_DIR  where fullchain.pem and privkey.pem are written (copy them to /etc/ssl/rickshawgo/)
#   DOMAIN   default: rickshawgo.azkar.test
#
# Why a private CA and not Let's Encrypt: *.test names are reserved and never resolve on the
# internet, so no public CA can validate them. On a real public domain the same Nginx config
# works with certbot (see README: "Real domain").

set -euo pipefail

CA_DIR="${1:-}"
OUT_DIR="${2:-}"
[ -n "$CA_DIR" ] && [ -n "$OUT_DIR" ] || { echo "Usage: $0 CA_DIR OUT_DIR [DOMAIN...]" >&2; exit 2; }
shift 2
DOMAINS=("$@")
[ "${#DOMAINS[@]}" -gt 0 ] || DOMAINS=(rickshawgo.azkar.test)

mkdir -p "$CA_DIR" "$OUT_DIR"
chmod 700 "$CA_DIR"
umask 077

# P-256 keys with a NAMED curve. (macOS LibreSSL's "req -newkey ec" writes explicit curve
# parameters, which OpenSSL 3 clients reject: "Certificate public key has explicit ECC parameters".)
new_key() { openssl ecparam -name prime256v1 -genkey -noout -param_enc named_curve -out "$1"; }

if [ ! -f "$CA_DIR/ca.key" ]; then
    echo "==> Creating the lab root CA in $CA_DIR (valid 5 years)"
    new_key "$CA_DIR/ca.key"
    openssl req -x509 -new -key "$CA_DIR/ca.key" -out "$CA_DIR/ca.crt" -days 1825 -sha256 \
        -subj "/O=Azkar DevOps Lab/CN=Azkar Lab Root CA" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign"
fi

san=""
for d in "${DOMAINS[@]}"; do san="${san:+$san,}DNS:$d"; done

echo "==> Issuing a certificate for: ${DOMAINS[*]} (valid 397 days)"
new_key "$OUT_DIR/privkey.pem"
openssl req -new -key "$OUT_DIR/privkey.pem" -out "$OUT_DIR/server.csr" -subj "/CN=${DOMAINS[0]}"
openssl x509 -req -in "$OUT_DIR/server.csr" -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
    -CAcreateserial -out "$OUT_DIR/server.crt" -days 397 -sha256 \
    -extfile <(printf 'subjectAltName=%s\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n' "$san")
# the chain the server sends: the server certificate (+ intermediates, none here). The root CA is
# never sent: clients must already trust it.
cp "$OUT_DIR/server.crt" "$OUT_DIR/fullchain.pem"
rm -f "$OUT_DIR/server.csr"

openssl verify -CAfile "$CA_DIR/ca.crt" "$OUT_DIR/server.crt"
openssl x509 -in "$OUT_DIR/server.crt" -noout -subject -issuer -enddate
openssl x509 -in "$OUT_DIR/server.crt" -noout -text | grep -A1 "Subject Alternative Name"
