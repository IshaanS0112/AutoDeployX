# Must be rejected by: log retention is bounded
resource "aws_cloudwatch_log_group" "bad" {
  name = "/ecs/example"
}
