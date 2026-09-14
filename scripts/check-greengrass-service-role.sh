#!/usr/bin/env bash
# Read-only check consumed by infra/10-account's `data "external"` block.
# Reports whether a Greengrass service role is already associated with this
# account and Region, WITHOUT ever associating, disassociating, or otherwise
# modifying anything. That account+Region association is shared by every lab
# and every person using this AWS account, so this script only ever reads.
#
# Input  (stdin):  a JSON object, {"region": "ap-northeast-1"} — the
#                   Terraform external data source's `query` argument.
# Output (stdout): a JSON object, {"role_arn": "<arn>"} if a service role is
#                   already associated, or {"role_arn": ""} if none is.
set -euo pipefail

query="$(cat)"
region="$(echo "$query" | jq -r '.region')"

# get-service-role-for-account returns no role metadata (empty/absent
# roleArn) when nothing is associated yet; it does not necessarily fail. It
# can also fail outright (e.g. ResourceNotFoundException on some accounts).
# Treat both as "nothing associated".
role_arn="$(/usr/local/bin/aws greengrassv2 get-service-role-for-account \
  --region "$region" \
  --query 'roleArn' \
  --output text 2>/dev/null)" || role_arn=""

if [ "$role_arn" = "None" ]; then
  role_arn=""
fi

jq -n --arg role_arn "$role_arn" '{role_arn: $role_arn}'
