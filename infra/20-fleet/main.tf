# Everything that changes per lab iteration. `terraform destroy` here is
# safe: it cannot remove the account-wide provisioning role or Greengrass
# service role, because this layer never created them (infra/10-account
# does, and only conditionally).

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_iot_endpoint" "data" { endpoint_type = "iot:Data-ATS" }
data "aws_iot_endpoint" "credentials" { endpoint_type = "iot:CredentialProvider" }

# Single-machine lab: read infra/10-account's local state file directly
# instead of publishing the role ARN to SSM Parameter Store. See that
# layer's README/comments if this ever needs to run from a different
# machine or account than 10-account was applied from.
data "terraform_remote_state" "account" {
  backend = "local"

  config = {
    path = "${path.module}/../10-account/terraform.tfstate"
  }
}

locals {
  account = data.aws_caller_identity.current.account_id
  region  = data.aws_region.current.region
  arn     = "arn:aws:iot:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}"
  prefix  = "lab/greengrass/devices"

  # Every future core follows this naming convention (lab-gg-core-01,
  # lab-gg-core-02, ...), same as client devices follow lab-gg-device-*. See
  # policies-core.tf for why this wildcard exists instead of
  # ${iot:Connection.Thing.ThingName}.
  core_thing_name_pattern = "lab-gg-core-*"
}

# The only targeting mechanism this lab uses; no resource here names an
# individual device.
resource "aws_iot_thing_group" "cores" { name = "lab-gg-cores" }
resource "aws_iot_thing_group" "clients" { name = "lab-gg-clients" }
