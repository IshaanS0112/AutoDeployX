# Must be rejected by: secrets have a zero recovery window
resource "aws_secretsmanager_secret" "bad" {
  name                    = "example/db"
  recovery_window_in_days = 30
}
