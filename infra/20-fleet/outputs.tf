output "iot_data_endpoint" {
  value = data.aws_iot_endpoint.data.endpoint_address
}

output "iot_credentials_endpoint" {
  value = data.aws_iot_endpoint.credentials.endpoint_address
}

output "core_thing_name" {
  value = aws_iot_thing.core.name
}

output "cores_group_arn" {
  value = aws_iot_thing_group.cores.arn
}

output "clients_group_arn" {
  value = aws_iot_thing_group.clients.arn
}

output "provisioning_template_name" {
  value = aws_iot_provisioning_template.client.name
}

output "token_exchange_role_alias" {
  value = aws_iot_role_alias.token_exchange.alias
}
