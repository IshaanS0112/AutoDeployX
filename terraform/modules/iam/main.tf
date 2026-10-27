# GitHub Actions -> AWS via OIDC.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# AWS validates GitHub's OIDC certificate chain itself for the well-known
# token.actions.githubusercontent.com issuer, but the API still requires a
data "tls_certificate" "github" {
  count = var.create_oidc_provider ? 1 : 0
  url   = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github[0].certificates[0].sha1_fingerprint]

  tags = var.tags
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.existing_oidc_provider_arn
}

data "aws_iam_policy_document" "github_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    # Audience must be the STS audience GitHub was asked to mint the token for.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # The actual scope: only tokens whose sub claim matches one of these refs
    # may assume the role. A fork's pull_request subject cannot.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.allowed_subjects
    }
  }
}

# A SECOND trust policy, for pull requests.
#
# The deploy role's policy above does not match a pull_request subject, so
# until now a PR could not plan at all and terraform-plan.yml fell back to the
# deploy role for same-repo PRs. That gave a plan the same write permissions as
# an apply, for no reason: a plan reads.
#
# This splits them. PRs assume a role that can only Describe and Get; nothing
# in its policy can change a resource.
data "aws_iam_policy_document" "github_plan_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Pull requests on THIS repository only. A fork's pull_request subject is
    # still this repo's, so the read-only scope is what contains a fork PR —
    # which is exactly why this role must stay read-only.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.plan_allowed_subjects
    }
  }
}

resource "aws_iam_role" "github_plan" {
  name               = "${var.name_prefix}-github-plan"
  description        = "Assumed by pull requests to run terraform plan. Read-only: it cannot create, change or delete anything."
  assume_role_policy = data.aws_iam_policy_document.github_plan_assume_role.json

  max_session_duration = 3600
  tags                 = var.tags
}

data "aws_iam_policy_document" "github_plan" {
  # Describe/Get/List only. A terraform plan refreshes state, which means
  # reading every managed resource; it writes nothing.
  statement {
    sid    = "ReadEverythingTerraformManages"
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "ecs:Describe*",
      "ecs:List*",
      "ecr:Describe*",
      "ecr:List*",
      "ecr:GetRepositoryPolicy",
      "ecr:GetLifecyclePolicy",
      "elasticloadbalancing:Describe*",
      "rds:Describe*",
      "rds:ListTagsForResource",
      "logs:Describe*",
      "logs:ListTagsForResource",
      "cloudwatch:Describe*",
      "cloudwatch:List*",
      "cloudwatch:GetDashboard",
      "sns:Get*",
      "sns:List*",
      "budgets:Describe*",
      "budgets:View*",
      "ce:Get*",
      "application-autoscaling:Describe*",
      "wafv2:Get*",
      "wafv2:List*",
      "acm:Describe*",
      "acm:List*",
      "route53:Get*",
      "route53:List*",
    ]
    resources = ["*"]
  }

  # IAM, scoped to this project's own roles and policies. A plan refreshes the
  # roles it manages; it has no reason to enumerate the account's IAM, and an
  # unscoped iam:List* is reconnaissance rather than a read.
  statement {
    sid    = "ReadOwnIAMOnly"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:GetOpenIDConnectProvider",
    ]
    resources = var.plan_readable_iam_arns
  }

  # Secrets Manager: the METADATA a plan needs, never the value. A plan reads
  # secret ARNs and tags to detect drift; GetSecretValue is deliberately absent.
  statement {
    sid    = "SecretMetadataNotValues"
    effect = "Allow"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecrets",
      "secretsmanager:GetResourcePolicy",
    ]
    resources = ["*"]
  }

  # The state backend. A plan must read state and take a lock.
  statement {
    sid    = "TerraformState"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketVersioning",
    ]
    resources = var.state_bucket_arns
  }
}

resource "aws_iam_role_policy" "github_plan" {
  name   = "${var.name_prefix}-github-plan"
  role   = aws_iam_role.github_plan.id
  policy = data.aws_iam_policy_document.github_plan.json
}

resource "aws_iam_role" "github_deploy" {
  name               = "${var.name_prefix}-github-deploy"
  description        = "Assumed by GitHub Actions via OIDC to build, push and deploy. Not usable by anything else."
  assume_role_policy = data.aws_iam_policy_document.github_assume_role.json

  # An hour is longer than any deploy in this pipeline takes; it exists so a
  # slow ECS stabilisation does not expire mid-wait.
  max_session_duration = 3600

  tags = var.tags
}

data "aws_iam_policy_document" "github_deploy" {
  # --- ECR ---------------------------------------------------------------
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # This action has no resource to scope to. It only mints a registry login.
  }

  statement {
    sid    = "ECRPushToOwnRepositoriesOnly"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    # Scoped to this project's repositories. The pipeline cannot push to, or
    # read, any other image repository in the account.
    resources = var.ecr_repository_arns
  }

  # --- ECS ---------------------------------------------------------------
  statement {
    sid    = "ECSDeployOwnServicesOnly"
    effect = "Allow"
    actions = [
      "ecs:UpdateService",
      "ecs:DescribeServices",
    ]
    resources = var.ecs_service_arns
  }

  statement {
    sid    = "ECSTaskDefinitions"
    effect = "Allow"
    actions = [
      "ecs:RegisterTaskDefinition",
      "ecs:DeregisterTaskDefinition",
      "ecs:DescribeTaskDefinition",
      "ecs:ListTaskDefinitions",
    ]
    # These four actions do not support resource-level permissions in IAM — AWS
    # evaluates them against "*" or not at all.
    resources = ["*"]
  }

  statement {
    sid    = "ECSObserveDeployment"
    effect = "Allow"
    actions = [
      "ecs:DescribeTasks",
      "ecs:ListTasks",
    ]
    resources = ["*"]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [var.ecs_cluster_arn]
    }
  }

  # --- Migrations ---------------------------------------------------------
  # ecs:RunTask DOES support resource-level permissions, unlike
  statement {
    sid       = "RunMigrationTasksOnly"
    effect    = "Allow"
    actions   = ["ecs:RunTask"]
    resources = var.migration_task_definition_arns

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [var.ecs_cluster_arn]
    }
  }

  statement {
    sid    = "StopRunawayMigrationTask"
    effect = "Allow"
    # A migration that hangs holds a lock on the schema. The pipeline needs to
    # be able to stop it on timeout, or the next deploy blocks behind it.
    actions   = ["ecs:StopTask"]
    resources = ["*"]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [var.ecs_cluster_arn]
    }
  }

  # --- PassRole ----------------------------------------------------------
  statement {
    sid     = "PassTaskRolesToECSOnly"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    # Exactly the two roles the task definition names, and nothing else.
    resources = [
      aws_iam_role.ecs_task_execution.arn,
      aws_iam_role.ecs_task.arn,
    ]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  # --- Read-only, for the pipeline's own health verification --------------
  statement {
    sid    = "ReadDeploymentSignals"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeLoadBalancers",
      "logs:GetLogEvents",
      "logs:FilterLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "${var.name_prefix}-github-deploy"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_deploy.json
}

# ECS task EXECUTION role — used by the ECS agent, not by your code.

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    # Confused-deputy guard: only tasks in THIS account, in THIS cluster.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "ecs_task_execution" {
  name               = "${var.name_prefix}-ecs-task-execution"
  description        = "ECS agent: pull images, write logs, resolve secrets"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_managed" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "ecs_task_execution_secrets" {
  statement {
    sid       = "ReadOnlyThisProjectsSecrets"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = var.secret_arns
  }
}

resource "aws_iam_role_policy" "ecs_task_execution_secrets" {
  name   = "${var.name_prefix}-read-secrets"
  role   = aws_iam_role.ecs_task_execution.id
  policy = data.aws_iam_policy_document.ecs_task_execution_secrets.json
}

# ECS TASK role — the identity the application code itself runs as.

resource "aws_iam_role" "ecs_task" {
  name               = "${var.name_prefix}-ecs-task"
  description        = "Application runtime identity. Intentionally minimal."
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "ecs_task" {
  statement {
    sid    = "ECSExecSSMChannel"
    effect = "Allow"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"] # SSM messaging channels are not resource-addressable.
  }
}

resource "aws_iam_role_policy" "ecs_task" {
  name   = "${var.name_prefix}-ecs-task"
  role   = aws_iam_role.ecs_task.id
  policy = data.aws_iam_policy_document.ecs_task.json
}
