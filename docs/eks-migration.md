# What moving this to EKS would involve, and what it would cost

**This is not built, and that is the decision — not an omission.** ADR 0009 is
the record. This document exists so the decision has a price attached, because
"I chose ECS" is an opinion and "I chose ECS because EKS is $73/month of
control plane before a single node, for capability this project does not need"
is an argument.

Every other expensive option in this repository was built as an opt-in switch
(`enable_nat_gateway`, `enable_waf`, `rds_multi_az`, …). EKS is the one that
stayed a document, for a reason worth stating: the others are *one resource*
behind a variable. EKS is a different orchestrator. It would mean a parallel
set of manifests, a second deployment path, a second rollback mechanism and a
second runbook — roughly doubling the repository to demonstrate the same
behaviour the ECS circuit breaker already demonstrates.

Knowing where that line is, is the point.

---

## The cost, before anything runs

| Line | Monthly | Note |
|---|---|---|
| EKS control plane | **$73.00** | $0.10/hour. Charged whether or not a single pod is scheduled. |
| Nodes — 2 × `t3.small` on-demand | $30.30 | Or Fargate profiles at roughly the current Fargate price. |
| NAT gateway | $32.85 | Effectively mandatory. Private node subnets are the assumed topology and most add-ons expect egress. |
| ALB via AWS Load Balancer Controller | $16.20 | Same ALB, provisioned by a controller instead of by Terraform. |
| RDS, unchanged | $13.10 | |
| **Total** | **~$165/month** | Against **~$48/month** for the current stack (`make cost`). |

**About 3.4× the cost, for the same two containers.**

Add `t3.medium` nodes, a managed node group per AZ, or Karpenter, and it grows
from there.

---

## What would actually change

| Today | On EKS |
|---|---|
| `aws_ecs_task_definition` | `Deployment` + `Service` manifests, or a Helm chart |
| `aws_ecs_service` with `deployment_circuit_breaker` | `Deployment` with `maxSurge`/`maxUnavailable`, plus **Argo Rollouts or Flagger** for automatic rollback — Kubernetes does not roll back on failing readiness probes by itself |
| ALB target group in Terraform | AWS Load Balancer Controller reconciling an `Ingress` |
| Two containers, one task, shared namespace | Two containers, one Pod, shared namespace — this one is a direct translation |
| Secrets Manager ARNs in the task definition | External Secrets Operator or the Secrets Store CSI driver, plus IRSA |
| Task role | IAM Roles for Service Accounts (IRSA), plus an OIDC provider for the cluster |
| `scripts/deploy.sh` polling `rolloutState` | `kubectl rollout status`, which has the **same trap**: it reports success for a Deployment that has already been rolled back |
| 8 Terraform modules | The same 8, plus cluster, node group, add-ons (CoreDNS, kube-proxy, VPC CNI, EBS CSI), and the controller's own IAM |

### The part people underestimate

**Kubernetes has no equivalent of the ECS deployment circuit breaker.** A
`Deployment` whose new pods never pass their readiness probe does not roll
back — it stalls, indefinitely, with the old ReplicaSet still serving. That is
arguably safer, and it is not the same thing: nothing reverts, nothing alerts,
and `kubectl rollout status` eventually times out.

Getting the behaviour this project already has means adding Argo Rollouts or
Flagger and writing an analysis template. That is the honest comparison —
**ECS gives it as a platform feature; on EKS it is a component you install,
configure and maintain.**

---

## What EKS would genuinely buy

Not nothing. Being able to argue this both ways is the point.

- **Portability.** Manifests run on any conformant cluster. A task definition runs on ECS.
- **The ecosystem.** Prometheus/Grafana, OpenTelemetry operators, Istio, cert-manager, Argo CD — all assume Kubernetes.
- **Richer scheduling.** Pod affinity, topology spread, taints. ECS has placement constraints and they are coarser.
- **Progressive delivery as a first-class thing.** Argo Rollouts does canary analysis properly; matching it on ECS means CodeDeploy or building it.
- **It is what the job adverts say.** A real consideration, and a bad reason to spend $117/month more on a portfolio project.

---

## When this decision should be revisited

- More than about five services — the per-service Terraform starts to feel like boilerplate a Helm chart would remove.
- A second team sharing the platform — namespaces and RBAC are a better answer than separate AWS accounts.
- A genuine need for canary analysis — although CodeDeploy blue/green on ECS gets most of the way first.
- Someone else is paying the $73/month.

Until then, ECS runs the same containers with the same rollout semantics and
the same rollback guarantee, and `make cost` says what the difference is.

---

## If you were going to do it anyway

The order that avoids the most rework:

1. `eksctl`-equivalent Terraform: cluster, one managed node group, OIDC provider.
2. AWS Load Balancer Controller + IRSA. Prove an `Ingress` provisions an ALB.
3. Translate one service. Keep the *other* on ECS — running both is the only way to compare them honestly.
4. External Secrets Operator against the same Secrets Manager entries.
5. Argo Rollouts, and re-run the deliberate-break drill from `runbook.md`. **If the drill does not end with traffic on the previous version, the migration is not finished**, whatever the pods say.
6. Only then move the second service and delete the ECS path.

Step 5 is the one that decides whether this was worth doing.
