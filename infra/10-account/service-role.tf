# The Greengrass service role association is one per account and Region.
# This AWS account is a shared sandbox with other people's resources in it,
# so this file must never disturb an association that already exists.
#
# data.external.greengrass_service_role is READ-ONLY: it only ever calls
# `greengrassv2 get-service-role-for-account` (see
# scripts/check-greengrass-service-role.sh). Every resource below is
# conditioned on its result being empty, so if a role is already associated,
# this entire file is inert — count is 0 everywhere, and nothing here ever
# calls associate-service-role-to-account.
data "external" "greengrass_service_role" {
  program = ["${path.module}/../../scripts/check-greengrass-service-role.sh"]

  query = {
    region = var.region
  }
}

locals {
  greengrass_service_role_exists = data.external.greengrass_service_role.result.role_arn != ""
}

# Created ONLY if no service role is associated with this account+Region yet
# — the association is a shared, account-level singleton, and this layer
# reuses whatever is already there rather than ever creating a second one.
resource "aws_iam_role" "greengrass_service" {
  count = local.greengrass_service_role_exists ? 0 : 1

  name = "lab-gg-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "greengrass.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:greengrass:${var.region}:${data.aws_caller_identity.current.account_id}:*" }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "greengrass_service" {
  count = local.greengrass_service_role_exists ? 0 : 1

  role       = aws_iam_role.greengrass_service[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGreengrassResourceAccessRolePolicy"
}

# associate-service-role-to-account has no CloudFormation type, so no
# Terraform or awscc resource exists for it — this is the one documented CLI
# escape hatch this layer needs. It is a leaf: nothing else in the graph
# depends on its result, it has NO drift detection, and (per the guard above)
# it only runs at all when this apply is the one creating lab-gg-service-role
# for the first time.
resource "terraform_data" "service_role_association" {
  count = local.greengrass_service_role_exists ? 0 : 1

  # Destroy-time provisioners may only reference the resource's own
  # attributes (self, count.index, each.key) — not var.* or other resources
  # — so the region is carried through `input`/`output` for the destroy
  # provisioner to read via `self.output`.
  input            = var.region
  triggers_replace = [aws_iam_role.greengrass_service[0].arn]

  provisioner "local-exec" {
    command = "aws greengrassv2 associate-service-role-to-account --role-arn ${aws_iam_role.greengrass_service[0].arn} --region ${var.region}"
  }

  # Only tears down the association this apply created. A role this layer
  # never created is never touched by anything in this file, on destroy or
  # otherwise.
  provisioner "local-exec" {
    when       = destroy
    command    = "aws greengrassv2 disassociate-service-role-from-account --region ${self.output}"
    on_failure = continue
  }

  depends_on = [aws_iam_role_policy_attachment.greengrass_service]
}

output "greengrass_service_role_arn" {
  description = "The service role actually associated with this account+Region: either the one this layer just created, or the pre-existing one it left untouched."
  value       = local.greengrass_service_role_exists ? data.external.greengrass_service_role.result.role_arn : aws_iam_role.greengrass_service[0].arn
}
