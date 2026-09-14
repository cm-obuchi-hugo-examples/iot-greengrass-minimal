#!/usr/bin/env bash
# Generates the shared claim identity's private key and CSR locally. The key
# never leaves this machine and is never read by Terraform: infra/20-fleet
# only consumes the CSR (var.claim_csr_path) to have AWS IoT sign a
# certificate for a key it never sees. Every client container mounts the
# resulting certificate read-only, and uses it only to provision itself —
# never for application data.
#
# Usage: scripts/gen-claim-csr.sh [--force]
set -euo pipefail

FORCE=0
if [ "${1:-}" = "--force" ]; then
  FORCE=1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="$REPO_ROOT/certs/claim"
KEY_FILE="$CERT_DIR/private.pem.key"
CSR_FILE="$CERT_DIR/claim.csr"
CA_FILE="$CERT_DIR/AmazonRootCA1.pem"

if [ -f "$KEY_FILE" ] && [ "$FORCE" -ne 1 ]; then
  echo "error: $KEY_FILE already exists." >&2
  echo "Regenerating it invalidates whatever certificate infra/20-fleet already signed for it," >&2
  echo "and every client container mounts this same key to provision itself." >&2
  echo "Re-run with --force if you really mean to replace the shared claim identity." >&2
  exit 1
fi

mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

openssl genrsa -out "$KEY_FILE" 2048
chmod 600 "$KEY_FILE"

openssl req -new \
  -key "$KEY_FILE" \
  -out "$CSR_FILE" \
  -subj "/CN=lab-gg-claim"

curl --fail --location \
  https://www.amazontrust.com/repository/AmazonRootCA1.pem \
  --output "$CA_FILE"

echo "Wrote $KEY_FILE (mode 0600), $CSR_FILE, and $CA_FILE."
echo "Next: terraform apply -chdir=infra/20-fleet -var=claim_csr_path=$CSR_FILE ..."
