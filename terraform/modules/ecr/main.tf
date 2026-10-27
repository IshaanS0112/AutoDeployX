# One ECR repository per container image.

resource "aws_ecr_repository" "this" {
  for_each = var.repositories

  name = each.key

  # Immutable tags are what make "roll back to a3f9c21" a defined operation.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    # Basic scanning is free.
    scan_on_push = true
  }

  # No KMS key: AES256 is the default, is free, and encrypts at rest. A CMK
  # would add $1/month for no threat-model change on a public portfolio image.
  encryption_configuration {
    encryption_type = "AES256"
  }

  force_delete = var.force_delete

  tags = merge(var.tags, { Name = each.key })
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged layers after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the last ${var.keep_last_images} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.keep_last_images
        }
        action = { type = "expire" }
      },
    ]
  })
}
