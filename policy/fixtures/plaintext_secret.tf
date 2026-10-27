# Must be rejected by: no plaintext secrets
resource "aws_ecs_task_definition" "bad" {
  family = "example"

  container_definitions = <<JSON
[{ "name" = "api", "environment" = [{ name = "DATABASE_PASSWORD", value = "hunter2" }] }]
JSON
}
