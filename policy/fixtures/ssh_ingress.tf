# Must be rejected by: no SSH ingress
resource "aws_vpc_security_group_ingress_rule" "bad" {
  security_group_id = "sg-123"
  cidr_ipv4         = "10.0.0.0/16"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}
