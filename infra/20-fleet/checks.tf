# Cloud-side halves of two of this lab's six minimal-verification claims
# (see README.md). Data sources live inside each `check` block, not at
# module scope, so a failed lookup becomes a check failure rather than
# blocking the whole plan/apply.

# Claim 1 — self-registration: "a device that never existed creates its own
# Thing and certificate, lands in lab-gg-clients, with no human action." The
# cloud-side half proven here is the core's own half of that claim: the core
# Thing genuinely is a member of lab-gg-cores in the live AWS IoT registry
# (not just in Terraform's state file), which is what lets a thing-group
# deployment and future client association reach it at all.
check "core_is_member_of_cores_group" {
  data "external" "core_group_membership" {
    program = ["${path.module}/../../scripts/check-thing-group-membership.sh"]

    query = {
      region           = var.region
      thing_name       = aws_iot_thing.core.name
      thing_group_name = aws_iot_thing_group.cores.name
    }
  }

  assert {
    condition     = data.external.core_group_membership.result.is_member == "true"
    error_message = "lab-gg-core-01 is not a member of lab-gg-cores in the live AWS IoT registry."
  }
}

# Claim 3 — local-only client MQTT: "clients reach the cloud only through
# the core, and no client policy grants cloud MQTT." Reads the live
# lab-gg-client-discovery policy (not just the document this configuration
# authored) and asserts it grants nothing beyond greengrass:Discover.
check "client_discovery_grants_only_discovery" {
  data "external" "client_discovery_policy_scope" {
    program = ["${path.module}/../../scripts/check-client-discovery-policy.sh"]

    query = {
      region      = var.region
      policy_name = aws_iot_policy.client_discovery.name
    }
  }

  assert {
    condition     = data.external.client_discovery_policy_scope.result.grants_cloud_mqtt == "false"
    error_message = "lab-gg-client-discovery grants cloud MQTT (Connect/Publish/Subscribe/Receive) beyond discovery."
  }
}
