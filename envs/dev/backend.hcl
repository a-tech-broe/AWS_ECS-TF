# Fill in bucket and kms_key_id from the `bootstrap` outputs, then run:
#   terraform init -backend-config=backend.hcl
bucket       = "REPLACE-ME-ecs-platform-tfstate-<account-id>"
key          = "dev/terraform.tfstate"
region       = "us-east-1"
encrypt      = true
kms_key_id   = "REPLACE-ME-state-kms-key-arn"
use_lockfile = true
