#!/usr/bin/env bash
# Read-only check consumed by infra/20-fleet's "core_is_member_of_cores_group"
# `check` block. Confirms group membership in the live AWS IoT registry,
# not just in Terraform's own state file. Never modifies anything.
#
# Input  (stdin):  a JSON object, {"region": "...", "thing_name": "...",
#                   "thing_group_name": "..."}.
# Output (stdout): a JSON object, {"is_member": "true"|"false"}.
set -euo pipefail

query="$(cat)"
region="$(echo "$query" | jq -r '.region')"
thing_name="$(echo "$query" | jq -r '.thing_name')"
thing_group_name="$(echo "$query" | jq -r '.thing_group_name')"

members="$(/usr/local/bin/aws iot list-things-in-thing-group \
  --region "$region" \
  --thing-group-name "$thing_group_name" \
  --query 'things' \
  --output json 2>/dev/null)" || members="[]"

is_member="$(echo "$members" | jq --arg name "$thing_name" 'any(.[]; . == $name)')"

jq -n --arg is_member "$is_member" '{is_member: $is_member}'
