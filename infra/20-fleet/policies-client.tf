# Everything a client device is granted in the cloud, and the shared claim
# identity clients use only to get there. No resource in this file ever
# names an individual client device.

locals {
  template_name = "lab-gg-client-template"
}

# The entire cloud permission a client device ever gets. No iot:Connect,
# iot:Publish, iot:Subscribe, or iot:Receive: a client physically cannot
# reach AWS IoT Core MQTT. All of its messaging permission is granted
# locally by the client device auth component (see deployment.tf).
#
# The wildcard is deliberate, not a placeholder for
# ${iot:Connection.Thing.ThingName}: discovery is an HTTPS call, not an MQTT
# connection, so it's untested whether that connection-scoped policy variable
# even substitutes there. The wildcard is correct either way, and is attached
# by the provisioning template below, not by a
# Terraform attachment resource, because the certificate it attaches to
# does not exist until a device creates it.
resource "aws_iot_policy" "client_discovery" {
  name = "lab-gg-client-discovery"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "greengrass:Discover"
      Resource = "${local.arn}:thing/lab-gg-device-*"
    }]
  })
}

# One shared certificate, used only to provision. The private key that
# produced this CSR was generated locally by scripts/gen-claim-csr.sh and
# never enters Terraform.
resource "aws_iot_certificate" "claim" {
  active = true
  csr    = file(var.claim_csr_path)
}

resource "local_file" "claim_certificate" {
  filename        = "${dirname(var.claim_csr_path)}/claim.pem.crt"
  content         = aws_iot_certificate.claim.certificate_pem
  file_permission = "0644"
}

# Provisioning and nothing else. Two properties make a shared credential
# acceptable: it can publish on no application topic at all, and it can call
# only one named template, so it cannot provision into another fleet.
resource "aws_iot_policy" "claim" {
  name = "lab-gg-claim"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "iot:Connect"
        Resource = "${local.arn}:client/claim-*"
      },
      {
        Effect = "Allow"
        Action = "iot:Publish"
        Resource = [
          "${local.arn}:topic/$aws/certificates/create-from-csr/json",
          "${local.arn}:topic/$aws/provisioning-templates/${local.template_name}/provision/json",
        ]
      },
      {
        Effect = "Allow"
        Action = "iot:Subscribe"
        Resource = [
          "${local.arn}:topicfilter/$aws/certificates/create-from-csr/json/accepted",
          "${local.arn}:topicfilter/$aws/certificates/create-from-csr/json/rejected",
          "${local.arn}:topicfilter/$aws/provisioning-templates/${local.template_name}/provision/json/accepted",
          "${local.arn}:topicfilter/$aws/provisioning-templates/${local.template_name}/provision/json/rejected",
        ]
      },
      {
        Effect = "Allow"
        Action = "iot:Receive"
        Resource = [
          "${local.arn}:topic/$aws/certificates/create-from-csr/json/accepted",
          "${local.arn}:topic/$aws/certificates/create-from-csr/json/rejected",
          "${local.arn}:topic/$aws/provisioning-templates/${local.template_name}/provision/json/accepted",
          "${local.arn}:topic/$aws/provisioning-templates/${local.template_name}/provision/json/rejected",
        ]
      },
    ]
  })
}

resource "aws_iot_policy_attachment" "claim" {
  policy = aws_iot_policy.claim.name
  target = aws_iot_certificate.claim.arn
}
