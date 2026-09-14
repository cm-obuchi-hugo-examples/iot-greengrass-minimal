#!/usr/bin/env bash
# Associates every current member of lab-gg-clients with the (Greengrass)
# core device, so a self-provisioned client can complete cloud discovery.
# BatchAssociateClientDeviceWithCoreDevice takes explicit Thing names and
# has no thing-group form, so this is the one operation AWS offers no
# declarative path for. Reads the live registry to decide what to
# associate, so it is unchanged whether 3 or 25 clients exist; no client
# Thing name is ever written into this script.
#
# Usage: scripts/associate.sh
set -euo pipefail

AWS=aws
REGION="ap-northeast-1"
CORE="lab-gg-core-01"  # the (Greengrass) core device; singular, fixed (Appendix A)
GROUP="lab-gg-clients" # the fleet's thing group; fixed, not a per-device name

# BatchAssociateClientDeviceWithCoreDevice's own limit on --entries per
# call. Confirmed against the AWS SDK's greengrassv2 service model
# (AssociateClientDeviceWithCoreDeviceEntryList: min 1 item, max 100 items),
# which matches the AWS API reference for this operation — not the 10 the
# hands-on manual guessed.
BATCH_SIZE=100

members_json="$("$AWS" iot list-things-in-thing-group \
  --thing-group-name "$GROUP" \
  --region "$REGION" \
  --query 'things' --output json)"

count="$(echo "$members_json" | jq 'length')"

if [ "$count" -eq 0 ]; then
  echo "no clients in $GROUP yet"
  exit 0
fi

associated=0
while IFS= read -r chunk; do
  entries="$(echo "$chunk" | jq -c '[.[] | {thingName: .}]')"

  "$AWS" greengrassv2 batch-associate-client-device-with-core-device \
    --core-device-thing-name "$CORE" \
    --region "$REGION" \
    --entries "$entries" >/dev/null

  chunk_count="$(echo "$chunk" | jq 'length')"
  associated=$((associated + chunk_count))
done < <(echo "$members_json" | jq -c --argjson n "$BATCH_SIZE" '
  to_entries
  | group_by((.key / $n) | floor)
  | map([.[].value])
  | .[]
')

echo "associated: $associated device(s)"
