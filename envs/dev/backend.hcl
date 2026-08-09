# Shared state backend for this account.
#
# NOTE: bucket "bokiti123" also holds state for unrelated projects, and the
# bare keys "dev/terraform.tfstate" and "prod/terraform.tfstate" are already
# taken by them. Every key here is namespaced under "ecs-platform/" so this
# platform can never adopt or overwrite another project's state.
#
#   terraform init -backend-config=backend.hcl
bucket         = "bokiti123"
key            = "ecs-platform/dev/terraform.tfstate"
region         = "us-east-1"
encrypt        = true
dynamodb_table = "family_dyning"
