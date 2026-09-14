variable "region" {
  description = "AWS Region for all fleet-layer IoT and Greengrass resources."
  type        = string
  default     = "ap-northeast-1"
}

variable "core_csr_path" {
  description = <<-EOT
    Path to the (Greengrass) core's certificate signing request, generated
    locally by scripts/gen-core-csr.sh (default output:
    certs/lab-gg-core-01/device.csr). Terraform only signs this CSR; the
    private key that produced it never enters Terraform state.
  EOT
  type        = string
}

variable "claim_csr_path" {
  description = <<-EOT
    Path to the shared claim identity's certificate signing request,
    generated locally by scripts/gen-claim-csr.sh (default output:
    certs/claim/claim.csr). Terraform only signs this CSR; the private key
    that produced it never enters Terraform state.
  EOT
  type        = string
}
