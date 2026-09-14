# The IAM-level boundary: the core trades its X.509 certificate for
# temporary AWS credentials, so no static AWS key ever enters the container.

resource "aws_iam_role" "token_exchange" {
  name = "lab-gg-token-exchange-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "credentials.iot.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Deliberately narrower than AWS's own default token-exchange policy
# (GreengrassV2TokenExchangeRoleAccess), which also grants logs:CreateLogGroup,
# logs:CreateLogStream, logs:PutLogEvents, and logs:DescribeLogStreams. This
# lab has no CloudWatch Logs and never deploys the Log Manager component (see
# the plan's non-goals), so those actions would be unused permissions with no
# corresponding component to use them. s3:GetBucketLocation alone is what
# supports resolving public component artifacts for this deployment.
resource "aws_iam_policy" "token_exchange" {
  name = "lab-gg-token-exchange-access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "s3:GetBucketLocation"
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "token_exchange" {
  role       = aws_iam_role.token_exchange.name
  policy_arn = aws_iam_policy.token_exchange.arn
}

resource "aws_iot_role_alias" "token_exchange" {
  alias               = "lab-gg-token-exchange-alias"
  role_arn            = aws_iam_role.token_exchange.arn
  credential_duration = 3600
}
