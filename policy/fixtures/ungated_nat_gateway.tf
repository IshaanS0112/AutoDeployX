# Must be rejected by: NAT gateway must be gated
resource "aws_nat_gateway" "bad" {
  allocation_id = "eipalloc-123"
  subnet_id     = "subnet-123"
}
