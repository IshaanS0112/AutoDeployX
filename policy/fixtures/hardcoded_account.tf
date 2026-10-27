# Must be rejected by: no hardcoded account id
resource "aws_iam_role_policy" "bad" {
  name   = "example"
  policy = "arn:aws:ecs:ap-south-1:123456789012:service/example/example"
}
