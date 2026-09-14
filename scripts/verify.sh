#!/usr/bin/env bash
# One function per claim in the plan's "Minimal verification" table
# (04-greengrass-v2.md). Contains no client device name or count literal:
# it discovers what is running from `podman ps` and what is registered from
# the live AWS IoT registry, the same way associate.sh does. This script
# must be byte-identical whether 3 or 25 clients exist — that repeat run is
# claim 5 (dynamism).
#
# Deliberately no `set -e`: a single failed assertion must not abort the
# rest of the run, or a script that stops at the first FAIL would print
# fewer "PASS"/"FAIL" lines than the claims it was asked to check.
#
# Claim 6 (core disposability) is only partially checkable here (registry
# status, volume presence) without doing the destructive recreate itself;
# the full test — stop, rm, recreate, compare certificate ARN — is a manual
# procedure, not something this script triggers on its own. See
# 04_smallsteps/06-verify-scale-and-teardown.md, section 3.
#
# aws is aliased to a 1Password shell plugin in this environment that fails
# non-interactively; always call the absolute binary, never the bare `aws`.
#
# Usage: scripts/verify.sh
set -uo pipefail

AWS=/usr/local/bin/aws
REGION="ap-northeast-1"
CORE="lab-gg-core-01"  # the (Greengrass) core device; singular, fixed (Appendix A)
GROUP="lab-gg-clients" # the fleet's thing group; fixed, not a per-device name
PREFIX="lab/greengrass/devices"

fail=0
check() {
  # $1: 0 for pass, non-zero for fail. $2: description.
  if [ "$1" -eq 0 ]; then
    echo "PASS  $2"
  else
    echo "FAIL  $2"
    fail=1
  fi
}

members_json="$("$AWS" iot list-things-in-thing-group \
  --thing-group-name "$GROUP" --region "$REGION" --query 'things' --output json)"
member_count="$(echo "$members_json" | jq 'length')"

running="$(podman ps --format '{{.Names}}' --filter name=lab-gg-client-)"
running_count=0
if [ -n "$running" ]; then
  running_count="$(echo "$running" | wc -l | tr -d ' ')"
fi

# ---------------------------------------------------------------------------
# Claim 1 — self-registration: every running replica has a registry Thing,
# with no human action beyond starting the container.
# ---------------------------------------------------------------------------
claim1_self_registration() {
  echo "--- claim 1: self-registration ---"
  if [ "$running_count" -eq 0 ]; then
    echo "SKIP  no running lab-gg-client-* containers"
    return
  fi

  for c in $running; do
    serial="${c#lab-gg-client-}"
    if echo "$members_json" | jq -e --arg t "lab-gg-device-$serial" 'any(.[]; . == $t)' >/dev/null; then
      check 0 "self-registration: lab-gg-device-$serial is a member of $GROUP"
    else
      check 1 "self-registration: lab-gg-device-$serial is a member of $GROUP"
    fi
  done
}

# ---------------------------------------------------------------------------
# Claim 2 — identity persistence: restarting a client reuses its stored
# certificate; the registry gains no new Thing.
# ---------------------------------------------------------------------------
claim2_identity_persistence() {
  echo "--- claim 2: identity persistence ---"
  if [ "$running_count" -eq 0 ]; then
    echo "SKIP  no running lab-gg-client-* containers"
    return
  fi

  target="$(echo "$running" | head -n1)"
  before="$member_count"

  restart_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ! podman restart "$target" >/dev/null 2>&1; then
    check 1 "$target: podman restart succeeded"
    return
  fi

  reused=1
  for _ in $(seq 1 30); do
    if podman logs --since "$restart_time" "$target" 2>&1 | grep -q "reusing stored identity"; then
      reused=0
      break
    fi
    sleep 2
  done
  check "$reused" "$target: restart log says 'reusing stored identity'"

  after_json="$("$AWS" iot list-things-in-thing-group \
    --thing-group-name "$GROUP" --region "$REGION" --query 'things' --output json)"
  after="$(echo "$after_json" | jq 'length')"

  if [ "$before" -eq "$after" ]; then
    check 0 "restarting $target created no new Thing ($before -> $after)"
  else
    check 1 "restarting $target created no new Thing ($before -> $after)"
  fi
}

# ---------------------------------------------------------------------------
# Claim 3 — local-only client MQTT: one certificate per Thing, only the
# discovery policy attached to it, and that policy grants no cloud MQTT.
# ---------------------------------------------------------------------------
claim3_local_only_mqtt() {
  echo "--- claim 3: local-only client MQTT ---"
  if [ "$member_count" -eq 0 ]; then
    echo "SKIP  no members of $GROUP yet"
  else
    while IFS= read -r t; do
      cert_count="$("$AWS" iot list-thing-principals --thing-name "$t" \
        --region "$REGION" --query 'length(principals)' --output text)"
      if [ "$cert_count" = "1" ]; then
        check 0 "exactly one certificate: $t"
      else
        check 1 "exactly one certificate: $t (found $cert_count)"
      fi

      arn="$("$AWS" iot list-thing-principals --thing-name "$t" \
        --region "$REGION" --query 'principals[0]' --output text)"
      pols="$("$AWS" iot list-attached-policies --target "$arn" \
        --region "$REGION" --query 'policies[].policyName' --output text)"
      if [ "$pols" = "lab-gg-client-discovery" ]; then
        check 0 "discovery policy only: $t"
      else
        check 1 "discovery policy only: $t (found [$pols])"
      fi
    done < <(echo "$members_json" | jq -r '.[]')
  fi

  document="$("$AWS" iot get-policy --policy-name lab-gg-client-discovery \
    --region "$REGION" --query policyDocument --output text)"

  if echo "$document" | grep -Eq '"iot:(Connect|Publish|Subscribe|Receive)"'; then
    check 1 "lab-gg-client-discovery grants no cloud MQTT"
  else
    check 0 "lab-gg-client-discovery grants no cloud MQTT"
  fi
}

claim3_direct_connection_refused() {
  # The negative half of claim 3: a client attempting direct cloud MQTT
  # (instead of going through the core) must be refused. Exercising this
  # needs a client image and one device's own stored certificate, and its
  # point is to observe an authorization failure, not to assert one
  # blindly — see 04_smallsteps/06-verify-scale-and-teardown.md, section 2,
  # for the exact manual procedure and the failure to look for.
  echo "SKIP  direct cloud MQTT refusal: run manually per 06-verify-scale-and-teardown.md section 2"
}

# ---------------------------------------------------------------------------
# Claim 4 — targeted delivery: a command to one randomly chosen member
# appears in that replica's log and no other.
# ---------------------------------------------------------------------------
claim4_targeted_delivery() {
  echo "--- claim 4: targeted delivery ---"
  if [ "$running_count" -eq 0 ]; then
    echo "SKIP  no running lab-gg-client-* containers"
    return
  fi

  idx=$(((RANDOM % running_count) + 1))
  target_container="$(echo "$running" | sed -n "${idx}p")"
  serial="${target_container#lab-gg-client-}"
  thing="lab-gg-device-${serial}"
  token="verify-$(date +%s)-$$"

  data_endpoint="$("$AWS" iot describe-endpoint --endpoint-type iot:Data-ATS \
    --region "$REGION" --query endpointAddress --output text)"

  if ! "$AWS" iot-data publish \
    --endpoint-url "https://${data_endpoint}" \
    --topic "$PREFIX/$thing/commands" \
    --qos 1 \
    --cli-binary-format raw-in-base64-out \
    --payload "{\"command\":\"setIndicator\",\"value\":\"$token\"}" \
    --region "$REGION"; then
    check 1 "publish to $PREFIX/$thing/commands succeeded"
    return
  fi

  sleep 5

  seen_target=1
  seen_elsewhere=0
  for c in $running; do
    if podman logs --since 30s "$c" 2>&1 | grep -q "$token"; then
      if [ "$c" = "$target_container" ]; then
        seen_target=0
      else
        seen_elsewhere=1
      fi
    fi
  done

  check "$seen_target" "command reached $target_container ($thing)"
  check "$seen_elsewhere" "command reached no other replica"
}

# ---------------------------------------------------------------------------
# Claim 5 — dynamism: this script is unchanged across fleet sizes. Nothing
# to assert beyond what claims 1-4 already checked at whatever size is
# currently running; recorded here only for the log.
# ---------------------------------------------------------------------------
claim5_dynamism() {
  echo "--- claim 5: dynamism ---"
  echo "INFO  checked $running_count running client container(s) and $member_count $GROUP member(s)"
  echo "INFO  re-run this unchanged script at a different CLIENT_COUNT to complete claim 5"
}

# ---------------------------------------------------------------------------
# Claim 6 — core disposability: only the non-destructive, checkable subset.
# The full test (stop, rm, recreate, compare certificate ARN) is a manual
# procedure — see 04_smallsteps/06-verify-scale-and-teardown.md, section 3.
# ---------------------------------------------------------------------------
claim6_core_disposability_checkable_subset() {
  echo "--- claim 6: core disposability (checkable subset) ---"

  status="$("$AWS" greengrassv2 list-core-devices --region "$REGION" \
    --query "coreDevices[?coreDeviceThingName=='$CORE'].status" --output text)"
  if [ "$status" = "HEALTHY" ]; then
    check 0 "$CORE is HEALTHY in the live Greengrass registry"
  else
    check 1 "$CORE is HEALTHY in the live Greengrass registry (found [$status])"
  fi

  if podman volume exists lab-gg-core-01-root 2>/dev/null; then
    check 0 "lab-gg-core-01-root volume exists (state survives container recreation)"
  else
    check 1 "lab-gg-core-01-root volume exists (state survives container recreation)"
  fi

  echo "INFO  full recreate test is manual: 06-verify-scale-and-teardown.md section 3"
}

claim1_self_registration
claim2_identity_persistence
claim3_local_only_mqtt
claim3_direct_connection_refused
claim4_targeted_delivery
claim5_dynamism
claim6_core_disposability_checkable_subset

exit "$fail"
