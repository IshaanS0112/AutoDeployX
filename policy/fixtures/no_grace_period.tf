# Must produce a WARNING (not a failure): health check grace period
resource "aws_ecs_service" "warn_only" {
  name            = "example"
  cluster         = "example"
  task_definition = "example:1"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    ignore_changes = [task_definition]
  }
}
