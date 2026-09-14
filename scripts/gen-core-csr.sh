#!/usr/bin/env bash
# Generates the (Greengrass) core's private key and CSR locally. The key
# never leaves this machine and is never read by Terraform: infra/20-fleet
# only consumes the CSR (var.core_csr_path) to have AWS IoT sign a
# certificate for a key it never sees.
#
# Usage: scripts/gen-core-csr.sh [--force]
set -euo pipefail

FORCE=0
if [ "${1:-}" = "--force" ]; then
  FORCE=1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="$REPO_ROOT/certs/lab-gg-core-01"
KEY_FILE="$CERT_DIR/private.pem.key"
CSR_FILE="$CERT_DIR/device.csr"
CA_FILE="$CERT_DIR/AmazonRootCA1.pem"

if [ -f "$KEY_FILE" ] && [ "$FORCE" -ne 1 ]; then
  echo "error: $KEY_FILE already exists." >&2
  echo "Regenerating it invalidates whatever certificate infra/20-fleet already signed for it." >&2
  echo "Re-run with --force if you really mean to replace the core's identity." >&2
  exit 1
fi

mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

openssl genrsa -out "$KEY_FILE" 2048
chmod 600 "$KEY_FILE"

openssl req -new \
  -key "$KEY_FILE" \
  -out "$CSR_FILE" \
  -subj "/CN=lab-gg-core-01"

curl --fail --location \
  https://www.amazontrust.com/repository/AmazonRootCA1.pem \
  --output "$CA_FILE"

echo "Wrote $KEY_FILE (mode 0600), $CSR_FILE, and $CA_FILE."
echo "Next: terraform apply -chdir=infra/20-fleet -var=core_csr_path=$CSR_FILE ..."
