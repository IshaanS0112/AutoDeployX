# Must be rejected by: no public database port
resource "aws_vpc_security_group_ingress_rule" "bad" {
  security_group_id = "sg-123"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
}
