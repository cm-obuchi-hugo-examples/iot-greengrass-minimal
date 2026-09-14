# Account-wide, rarely-changing resources. `terraform destroy` here is never
# expected as a matter of routine: infra/20-fleet iterates per lab change,
# this layer does not.

data "aws_caller_identity" "current" {}

# AWS IoT assumes this role while running fleet provisioning by claim (the
# template in infra/20-fleet) to create Things, attach IoT policies, and
# activate the certificates devices generate from their own CSR.
#
# AWS's own fleet-provisioning guide says to attach the AWS-managed
# AWSIoTThingsRegistration policy to this role rather than hand-listing
# actions:
# https://docs.aws.amazon.com/iot/latest/developerguide/provision-wo-cert.html
# ("Give the AWS IoT service permission to create or update IoT resources
# such as things and certificates in your account when provisioning devices.
# Do this by attaching the AWSIoTThingsRegistration managed policy to an IAM
# role (called the provisioning role) that trusts the AWS IoT service
# principal.") That covers iot:CreateThing, iot:CreateCertificateFromCsr,
# iot:RegisterThing, iot:AttachThingPrincipal, iot:AttachPolicy,
# iot:AddThingToThingGroup, and the handful of related actions the
# provisioning template's Resources section can invoke, without hand-rolling
# a policy that has to be kept in sync with what the template supports.
resource "aws_iam_role" "provisioning" {
  name = "lab-gg-provisioning-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "iot.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "provisioning" {
  role       = aws_iam_role.provisioning.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSIoTThingsRegistration"
}

output "provisioning_role_arn" {
  description = "The role infra/20-fleet's provisioning template assumes to register devices."
  value       = aws_iam_role.provisioning.arn
}
