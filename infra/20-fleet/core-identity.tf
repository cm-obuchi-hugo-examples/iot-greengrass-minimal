# The (Greengrass) core Thing and its one certificate. Every client Thing,
# by contrast, is created by the device itself at first boot (see
# provisioning-template.tf) — this is the one identity a human creates.

resource "aws_iot_thing" "core" { name = "lab-gg-core-01" }

resource "aws_iot_thing_group_membership" "core" {
  thing_name       = aws_iot_thing.core.name
  thing_group_name = aws_iot_thing_group.cores.name
}

# The private key that produced this CSR was generated locally by
# scripts/gen-core-csr.sh and never enters Terraform.
resource "aws_iot_certificate" "core" {
  active = true
  csr    = file(var.core_csr_path)
}

resource "aws_iot_thing_principal_attachment" "core" {
  thing     = aws_iot_thing.core.name
  principal = aws_iot_certificate.core.arn
}

# The certificate PEM is public; only the private key is secret, and that
# key never passes through Terraform. Written next to the CSR so the core
# container can mount the same directory read-only.
resource "local_file" "core_certificate" {
  filename        = "${dirname(var.core_csr_path)}/device.pem.crt"
  content         = aws_iot_certificate.core.certificate_pem
  file_permission = "0644"
}
