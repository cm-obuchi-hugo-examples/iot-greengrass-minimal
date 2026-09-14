# This is where a client device's identity is decided; the device only
# supplies a SerialNumber. The template, not the device, chooses the Thing
# name, the group, and the policy.
resource "aws_iot_provisioning_template" "client" {
  name                  = local.template_name
  provisioning_role_arn = data.terraform_remote_state.account.outputs.provisioning_role_arn
  enabled               = true

  template_body = jsonencode({
    Parameters = {
      SerialNumber                = { Type = "String" }
      "AWS::IoT::Certificate::Id" = { Type = "String" }
    }
    Resources = {
      thing = {
        Type = "AWS::IoT::Thing"
        Properties = {
          ThingName        = { "Fn::Join" = ["", ["lab-gg-device-", { Ref = "SerialNumber" }]] }
          AttributePayload = { serialNumber = { Ref = "SerialNumber" } }
          ThingGroups      = [aws_iot_thing_group.clients.name]
        }
        OverrideSettings = {
          AttributePayload = "MERGE"
          ThingGroups      = "DO_NOTHING"
        }
      }
      certificate = {
        Type = "AWS::IoT::Certificate"
        Properties = {
          CertificateId      = { Ref = "AWS::IoT::Certificate::Id" }
          Status             = "ACTIVE"
          ThingPrincipalType = "EXCLUSIVE_THING"
        }
      }
      policy = {
        Type       = "AWS::IoT::Policy"
        Properties = { PolicyName = aws_iot_policy.client_discovery.name }
      }
    }
  })
}
