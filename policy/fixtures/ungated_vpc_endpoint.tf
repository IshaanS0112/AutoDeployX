# Must be rejected by: interface endpoints must be gated
resource "aws_vpc_endpoint" "bad" {
  vpc_id            = "vpc-123"
  service_name      = "com.amazonaws.ap-south-1.ecr.api"
  vpc_endpoint_type = "Interface"
}
