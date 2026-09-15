#!/usr/bin/env bash
# Generates the (Greengrass) core's config/config.yaml from infra/20-fleet's
# live Terraform outputs, instead of hand-copying endpoint hostnames into a
# static file. Safe to re-run any time those outputs might have changed;
# it only ever overwrites
# config/config.yaml and client.env at the repo root, never Terraform state
# or any cloud resource.
#
# Also generates client.env (IOT_DATA_ENDPOINT only): provision.py needs the
# account's real IoT data endpoint on first boot, and that value must not be
# hand-typed into local/compose.yaml, which is committed. Both
# config/config.yaml and client.env are gitignored; greengrass.env is not
# generated here because it contains no endpoint (it is a small, static file
# checked into the repo).
#
# Usage: scripts/gen-core-config.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLEET_DIR="$REPO_ROOT/infra/20-fleet"
CONFIG_DIR="$REPO_ROOT/config"

if [ ! -d "$FLEET_DIR" ]; then
  echo "error: $FLEET_DIR not found." >&2
  exit 1
fi

DATA_EP="$(terraform -chdir="$FLEET_DIR" output -raw iot_data_endpoint)"
CRED_EP="$(terraform -chdir="$FLEET_DIR" output -raw iot_credentials_endpoint)"
CORE_THING="$(terraform -chdir="$FLEET_DIR" output -raw core_thing_name)"
ROLE_ALIAS="$(terraform -chdir="$FLEET_DIR" output -raw token_exchange_role_alias)"

if [ -z "$DATA_EP" ] || [ -z "$CRED_EP" ]; then
  echo "error: empty endpoint from 'terraform output' in $FLEET_DIR." >&2
  echo "Did you run 'terraform apply' there yet?" >&2
  exit 1
fi

if [[ "$DATA_EP" == https://* || "$CRED_EP" == https://* ]]; then
  echo "error: an endpoint output includes a scheme (https://); Nucleus expects a bare hostname." >&2
  exit 1
fi

mkdir -p "$CONFIG_DIR"

cat >"$CONFIG_DIR/config.yaml" <<YAML
---
system:
  certificateFilePath: "/tmp/certs/device.pem.crt"
  privateKeyPath: "/tmp/certs/private.pem.key"
  rootCaPath: "/tmp/certs/AmazonRootCA1.pem"
  rootpath: "/greengrass/v2"
  thingName: "${CORE_THING}"
services:
  aws.greengrass.Nucleus:
    componentType: "NUCLEUS"
    version: "2.18.3"
    configuration:
      awsRegion: "ap-northeast-1"
      iotRoleAlias: "${ROLE_ALIAS}"
      iotDataEndpoint: "${DATA_EP}"
      iotCredEndpoint: "${CRED_EP}"
YAML

# Consumed by local/compose.yaml's `client` service via `env_file:
# ../client.env`. AWS_REGION is not written here: it is a fixed lab
# constant, not an account-specific value Terraform owns, so it is set
# directly in local/compose.yaml instead.
cat >"$REPO_ROOT/client.env" <<ENV
IOT_DATA_ENDPOINT=${DATA_EP}
ENV

echo "Wrote $CONFIG_DIR/config.yaml and $REPO_ROOT/client.env."
