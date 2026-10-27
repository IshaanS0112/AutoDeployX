# Must be rejected by: no :latest image tag
resource "aws_ecs_task_definition" "bad" {
  family = "example"
  image  = "123456789012.dkr.ecr.ap-south-1.amazonaws.com/autodeployx/finsight-api:latest"
}
