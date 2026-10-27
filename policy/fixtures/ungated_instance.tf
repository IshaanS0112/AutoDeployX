# Must be rejected by: billable instances must be gated
resource "aws_instance" "bad" {
  ami           = "ami-123"
  instance_type = "t4g.nano"
}
