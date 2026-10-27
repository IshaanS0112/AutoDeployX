# Must be rejected by: migrations module must exist alongside service
module "service" {
  source      = "./modules/ecs-service"
  name_prefix = "example"
}
