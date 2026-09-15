# The three core IoT policies. All three attach to the one core certificate;
# AWS evaluates their union. The three-way split is for a human to read which
# permission serves which purpose: lab-gg-core-runtime (Nucleus/MQTT Bridge
# cloud runtime), lab-gg-core-client-auth (verifying client devices),
# lab-gg-core-bridge (relaying application topics).
#
# ${iot:Connection.Thing.ThingName} is deliberately NOT used here, even
# though it would let a single core policy read as correct for any future
# core. AWS IoT's own docs rule it out for policies attached to a Greengrass
# core device:
#
#   "Thing policy variables (iot:Connection.Thing.*) aren't supported ... in
#   AWS IoT policies for core devices or Greengrass data plane operations.
#   Instead, you can use a wildcard that matches multiple devices that have
#   similar names."
#   (https://docs.aws.amazon.com/greengrass/v2/developerguide/device-auth.html)
#
# AWS's own published "minimal AWS IoT policy for core devices" example uses
# a literal thing name with a trailing wildcard for exactly this reason
# (e.g. "client/core-device-thing-name*"), not the connection variable. This
# file follows that guidance to get the same result — a policy that reads
# as correct for any future core, not just lab-gg-core-01 — using the
# AWS-recommended mechanism: a wildcard over the lab-gg-core-* naming
# convention (local.core_thing_name_pattern, defined in main.tf), the same
# way client Things are matched by lab-gg-device-*.
resource "aws_iot_policy" "core_runtime" {
  name = "lab-gg-core-runtime"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "iot:Connect"
        Resource = "${local.arn}:client/${local.core_thing_name_pattern}"
      },
      {
        Effect = "Allow"
        Action = ["iot:Publish", "iot:Receive"]
        Resource = [
          "${local.arn}:topic/$aws/things/${local.core_thing_name_pattern}/greengrassv2/health/json",
          "${local.arn}:topic/$aws/things/${local.core_thing_name_pattern}/jobs/*",
          "${local.arn}:topic/$aws/things/${local.core_thing_name_pattern}/shadow/*",
        ]
      },
      {
        Effect = "Allow"
        Action = "iot:Subscribe"
        Resource = [
          "${local.arn}:topicfilter/$aws/things/${local.core_thing_name_pattern}/jobs/*",
          "${local.arn}:topicfilter/$aws/things/${local.core_thing_name_pattern}/shadow/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = "iot:AssumeRoleWithCertificate"
        Resource = aws_iot_role_alias.token_exchange.arn
      },
      {
        Effect = "Allow"
        Action = [
          "greengrass:GetComponentVersionArtifact",
          "greengrass:ResolveComponentCandidates",
          "greengrass:GetDeploymentConfiguration",
          "greengrass:ListThingGroupsForCoreDevice",
        ]
        Resource = "*"
      },
    ]
  })
}

# Note the wildcard where the first plan (see the design doc's history)
# listed three client Thing ARNs by name.
resource "aws_iot_policy" "core_client_auth" {
  name = "lab-gg-core-client-auth"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "greengrass:PutCertificateAuthorities",
          "greengrass:VerifyClientDeviceIdentity",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "greengrass:VerifyClientDeviceIoTCertificateAssociation"
        Resource = "${local.arn}:thing/lab-gg-device-*"
      },
      {
        Effect   = "Allow"
        Action   = ["greengrass:GetConnectivityInfo", "greengrass:UpdateConnectivityInfo"]
        Resource = "${local.arn}:thing/${local.core_thing_name_pattern}"
      },
      {
        Effect   = "Allow"
        Action   = "iot:Publish"
        Resource = "${local.arn}:topic/$aws/things/${local.core_thing_name_pattern}-gci/shadow/get"
      },
      {
        Effect = "Allow"
        Action = ["iot:Subscribe", "iot:Receive"]
        Resource = [
          "${local.arn}:topicfilter/$aws/things/${local.core_thing_name_pattern}-gci/shadow/update/delta",
          "${local.arn}:topicfilter/$aws/things/${local.core_thing_name_pattern}-gci/shadow/get/accepted",
          "${local.arn}:topic/$aws/things/${local.core_thing_name_pattern}-gci/shadow/update/delta",
          "${local.arn}:topic/$aws/things/${local.core_thing_name_pattern}-gci/shadow/get/accepted",
        ]
      },
    ]
  })
}

# Topic wildcards instead of enumerating individual devices' telemetry and
# command topics. This policy never referenced a connection variable in the
# manual either, so it needs no change: `*` and `+` here are already the
# device-count-agnostic mechanism AWS IoT policies support.
resource "aws_iot_policy" "core_bridge" {
  name = "lab-gg-core-bridge"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "iot:Publish"
        Resource = "${local.arn}:topic/${local.prefix}/*/telemetry"
      },
      {
        Effect   = "Allow"
        Action   = "iot:Subscribe"
        Resource = "${local.arn}:topicfilter/${local.prefix}/+/commands"
      },
      {
        Effect   = "Allow"
        Action   = "iot:Receive"
        Resource = "${local.arn}:topic/${local.prefix}/*/commands"
      },
    ]
  })
}

resource "aws_iot_policy_attachment" "core" {
  for_each = {
    runtime     = aws_iot_policy.core_runtime.name
    client_auth = aws_iot_policy.core_client_auth.name
    bridge      = aws_iot_policy.core_bridge.name
  }

  policy = each.value
  target = aws_iot_certificate.core.arn
}
