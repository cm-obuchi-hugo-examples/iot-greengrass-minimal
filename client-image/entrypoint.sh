#!/bin/sh
# Idempotent client entrypoint: provision once, then discover-and-connect
# forever (with backoff). See research-plans/04_greengrass/04_smallsteps/
# 05-self-provisioning-client-fleet.md, section 3, for the design this
# implements.
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

# A device can boot before scripts/associate.sh has run, so discovery
# retries with exponential backoff (5s, doubling, capped at 60s) instead of
# failing once and staying down.
delay=5
while true; do
  if python3 -u /app/basic_discovery.py \
      --thing_name "$THING" \
      --topic "lab/greengrass/devices/${THING}/commands" \
      --message "hello from ${THING}" \
      --mode both \
      --ca_file /claim/AmazonRootCA1.pem \
      --cert "$DIR/device.pem.crt" \
      --key "$DIR/private.pem.key" \
      --region "${AWS_REGION:-ap-northeast-1}"
  then
    break
  fi
  echo "discovery or local connect failed; retrying in ${delay}s"
  sleep "$delay"
  delay=$((delay * 2))
  [ "$delay" -gt 60 ] && delay=60
done

# If this SDK version's basic_discovery.py sample rejects --mode both,
# publish once with --mode publish and then re-exec with --mode subscribe
# instead — never run two processes under one Thing name at once: both use
# it as the MQTT client ID, and Moquette disconnects whichever session
# connected first.
