# Must be rejected by: circuit breaker enabled, and by ignore_changes
resource "aws_ecs_service" "bad" {
  name            = "example"
  cluster         = "arn:aws:ecs:ap-south-1:000000000000:cluster/example"
  task_definition = "example:1"
  desired_count   = 1

  health_check_grace_period_seconds = 90
}
