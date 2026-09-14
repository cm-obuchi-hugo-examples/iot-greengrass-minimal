# Deploys the four client-device components alongside the Nucleus to the
# lab-gg-cores thing group — not to a named core device. A second gateway
# added to that group later inherits this deployment with no new Terraform.
#
# hashicorp/aws 6.62.0 has no Greengrass V2 resources at all (confirmed by
# grepping the provider binary); awscc's schema (checked against the
# installed hashicorp/awscc ~> 1.0 provider) is the only source for this
# resource's shape, so component_version and configuration_update.merge
# below are taken from that schema, not guessed from the CLI's JSON shape.

locals {
  # Client device auth's selection rule syntax is verified against
  # https://docs.aws.amazon.com/greengrass/v2/developerguide/client-device-auth-component.html:
  # "Use the * wildcard ... at the beginning and end of the thing name to
  # match client devices whose names start or end with the string that you
  # specify." and the documented example `thingName: MyClientDevice*` is
  # exactly this pattern, so `thingName: lab-gg-device-*` (not `mqtt:*`, and
  # not a literal list) is correct as written.
  client_device_auth_config = {
    deviceGroups = {
      formatVersion = "2021-03-05"
      definitions = {
        LabClientDevices = {
          selectionRule = "thingName: lab-gg-device-*"
          policyName    = "LabClientDevicePolicy"
        }
      }
      policies = {
        LabClientDevicePolicy = {
          AllowConnect = {
            statementDescription = "Allow any authenticated lab client to connect."
            operations           = ["mqtt:connect"]
            resources            = ["*"]
          }
          AllowOwnTelemetry = {
            statementDescription = "Allow a client to publish only its own telemetry."
            operations           = ["mqtt:publish"]
            resources            = ["mqtt:topic:${local.prefix}/$${iot:Connection.Thing.ThingName}/telemetry"]
          }
          AllowOwnCommands = {
            statementDescription = "Allow a client to subscribe only to its own commands."
            operations           = ["mqtt:subscribe"]
            resources            = ["mqtt:topicfilter:${local.prefix}/$${iot:Connection.Thing.ThingName}/commands"]
          }
        }
      }
    }
  }

  # MQTT Bridge's mqttTopicMapping schema (topic/source/target) is verified
  # against
  # https://docs.aws.amazon.com/greengrass/v2/developerguide/mqtt-bridge-component.html.
  # The `+` wildcard means the relay never needed a device count; there is
  # no `#` catch-all, so traffic on any other topic is not relayed either
  # direction.
  bridge_config = {
    mqttTopicMapping = {
      ClientTelemetryToIotCore = {
        topic  = "${local.prefix}/+/telemetry"
        source = "LocalMqtt"
        target = "IotCore"
      }
      IotCoreCommandsToClients = {
        topic  = "${local.prefix}/+/commands"
        source = "IotCore"
        target = "LocalMqtt"
      }
    }
  }
}

resource "awscc_greengrassv2_deployment" "gateway" {
  target_arn      = aws_iot_thing_group.cores.arn
  deployment_name = "lab-gg-client-gateway"

  components = {
    "aws.greengrass.Nucleus" = {
      component_version = "2.18.3"
    }
    "aws.greengrass.clientdevices.Auth" = {
      component_version = "2.5.7"
      configuration_update = {
        merge = jsonencode(local.client_device_auth_config)
      }
    }
    "aws.greengrass.clientdevices.mqtt.Moquette" = {
      component_version = "2.3.7"
    }
    "aws.greengrass.clientdevices.mqtt.Bridge" = {
      component_version = "2.3.3"
      configuration_update = {
        merge = jsonencode(local.bridge_config)
      }
    }
    "aws.greengrass.clientdevices.IPDetector" = {
      component_version = "2.2.5"
    }
  }
}
