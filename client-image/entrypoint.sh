#!/bin/sh
# Idempotent client entrypoint: provision once, then discover-and-connect
# forever (with backoff). See README.md's "Concept" section for the design
# this implements.
#
# SERIAL falls back to the container's own hostname, so this image works
# unmodified whether SERIAL is set explicitly (a manual `podman run --env
# SERIAL=...`) or left to whatever Podman auto-generates for this replica.
# local/compose.yaml's `client` service relies on the latter — see the
# comment there on why replicas get no `hostname:`.
set -eu

SERIAL="${SERIAL:-$(hostname)}"
THING="lab-gg-device-${SERIAL}"
DIR="/data/${SERIAL}"

mkdir -p "$DIR"
chmod 700 "$DIR"

if [ -f "$DIR/device.pem.crt" ]; then
  echo "reusing stored identity for ${THING}"
else
  echo "no identity for ${THING}; provisioning"

  openssl genrsa -out "$DIR/private.pem.key" 2048
  chmod 600 "$DIR/private.pem.key"
  openssl req -new -key "$DIR/private.pem.key" \
    -out "$DIR/device.csr" -subj "/CN=${THING}"

  python3 -u /app/provision.py \
    --serial "$SERIAL" \
    --csr "$DIR/device.csr" \
    --out "$DIR/device.pem.crt"
fi

# A device can boot before scripts/associate.sh has run, and the local
# connection can be lost at any point after that (core restart, network
# blip, the core's own local IP changing). client.py is meant to run
# forever once connected — it only ever exits (non-zero) on a failed
# discovery, a failed initial connection, or a lost connection, and
# deliberately does not retry or resubscribe on its own (see client.py's
# module docstring). So every exit, for any reason, is retried here from
# scratch (fresh discovery included) with exponential backoff (5s,
# doubling, capped at 60s).
delay=5
while true; do
  if python3 -u /app/client.py \
      --thing_name "$THING" \
      --cert "$DIR/device.pem.crt" \
      --key "$DIR/private.pem.key" \
      --ca_file /claim/AmazonRootCA1.pem \
      --region "${AWS_REGION:-ap-northeast-1}"
  then
    echo "client.py exited 0 (unexpected — it's meant to run forever)"
  else
    echo "client.py exited non-zero"
  fi
  echo "retrying in ${delay}s"
  sleep "$delay"
  delay=$((delay * 2))
  [ "$delay" -gt 60 ] && delay=60
done
