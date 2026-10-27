# Must be rejected by: circuit breaker rollback
resource "aws_ecs_service" "bad" {
  name            = "example"
  cluster         = "example"
  task_definition = "example:1"

  health_check_grace_period_seconds = 90

  deployment_circuit_breaker {
    enable   = true
    rollback = false
  }

  lifecycle {
    ignore_changes = [task_definition]
  }
}
