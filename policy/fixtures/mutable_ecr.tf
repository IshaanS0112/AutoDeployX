# Must be rejected by: ECR tags immutable
resource "aws_ecr_repository" "bad" {
  name                 = "autodeployx/example"
  image_tag_mutability = "MUTABLE"
}
