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

if [ ! -f "$CA_DIR/ca.key" ]; then
    echo "==> Creating the lab root CA in $CA_DIR (valid 5 years)"
    openssl req -x509 -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$CA_DIR/ca.key" -out "$CA_DIR/ca.crt" -days 1825 \
        -subj "/O=Azkar DevOps Lab/CN=Azkar Lab Root CA" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign"
fi

san=""
for d in "${DOMAINS[@]}"; do san="${san:+$san,}DNS:$d"; done

echo "==> Issuing a certificate for: ${DOMAINS[*]} (valid 397 days)"
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$OUT_DIR/privkey.pem" -out "$OUT_DIR/server.csr" -subj "/CN=${DOMAINS[0]}"
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
