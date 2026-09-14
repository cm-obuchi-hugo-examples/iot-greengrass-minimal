#!/usr/bin/env bash
# Removes every self-provisioned client Thing: for each member of
# lab-gg-clients, detach its policy, detach its certificate (principal),
# deactivate and delete the certificate, then delete the Thing itself.
# Mirrors associate.sh's shape — read the live registry, then act on
# whatever is a member — because these Things were created by devices at
# runtime; infra/20-fleet's Terraform never tracked them, so `terraform
# destroy` alone would leave them behind. No client Thing name is ever
# written into this script.
#
# aws is aliased to a 1Password shell plugin in this environment that fails
# non-interactively; always call the absolute binary, never the bare `aws`.
#
# Usage: scripts/cleanup-clients.sh
set -euo pipefail

AWS=/usr/local/bin/aws
REGION="ap-northeast-1"
GROUP="lab-gg-clients" # the fleet's thing group; fixed, not a per-device name

members="$("$AWS" iot list-things-in-thing-group \
  --thing-group-name "$GROUP" --region "$REGION" \
  --query 'things' --output text)"

if [ -z "$members" ]; then
  echo "no clients in $GROUP; nothing to clean up"
  exit 0
fi

cleaned=0
for thing in $members; do
  echo "cleaning up $thing"

  principals="$("$AWS" iot list-thing-principals --thing-name "$thing" \
    --region "$REGION" --query 'principals' --output text)"

  for arn in $principals; do
    cert_id="${arn##*/}"

    policies="$("$AWS" iot list-attached-policies --target "$arn" \
      --region "$REGION" --query 'policies[].policyName' --output text)"
    for policy in $policies; do
      "$AWS" iot detach-policy --policy-name "$policy" --target "$arn" --region "$REGION"
    done

    "$AWS" iot detach-thing-principal --thing-name "$thing" --principal "$arn" --region "$REGION"
    "$AWS" iot update-certificate --certificate-id "$cert_id" --new-status INACTIVE --region "$REGION"
    "$AWS" iot delete-certificate --certificate-id "$cert_id" --region "$REGION"
  done

  "$AWS" iot delete-thing --thing-name "$thing" --region "$REGION"
  cleaned=$((cleaned + 1))
done

echo "cleaned up $cleaned client thing(s)"
