# Must be rejected by: budgets module is present
module "networking" {
  source      = "./modules/networking"
  name_prefix = "example"
}
