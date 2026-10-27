output "budget_names" {
  value = [for b in aws_budgets_budget.monthly : b.name]
}
