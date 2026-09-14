#!/usr/bin/env bash
# Read-only check consumed by infra/20-fleet's
# "client_discovery_grants_only_discovery" `check` block. Confirms the live
# lab-gg-client-discovery IoT policy grants no cloud MQTT (iot:Connect,
# iot:Publish, iot:Subscribe, iot:Receive) alongside greengrass:Discover.
# Never modifies anything.
#
# Input  (stdin):  a JSON object, {"region": "...", "policy_name": "..."}.
# Output (stdout): a JSON object, {"grants_cloud_mqtt": "true"|"false"}.
set -euo pipefail

query="$(cat)"
region="$(echo "$query" | jq -r '.region')"
policy_name="$(echo "$query" | jq -r '.policy_name')"

document="$(aws iot get-policy \
  --region "$region" \
  --policy-name "$policy_name" \
  --query 'policyDocument' \
  --output text 2>/dev/null)" || document='{"Statement":[]}'

grants_cloud_mqtt="$(echo "$document" | jq '
  [ .Statement[]
    | select(.Effect == "Allow")
    | (.Action | if type == "array" then . else [.] end)[]
    | select(. == "iot:Connect" or . == "iot:Publish" or . == "iot:Subscribe" or . == "iot:Receive")
  ] | length > 0
')"

jq -n --arg v "$grants_cloud_mqtt" '{grants_cloud_mqtt: $v}'
