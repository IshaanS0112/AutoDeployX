# Must be rejected by: migration task must not hold a connection pool
resource "aws_ecs_task_definition" "bad" {
  family = "example-migrate"

  container_definitions = <<JSON
[{ "name" = "migrate", "environment" = [{ name = "DB_POOL_SIZE", value = "10" }] }]
JSON
}
