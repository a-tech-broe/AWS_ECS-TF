terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Partial configuration; the remaining values come from backend.hcl.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = "shared"
      ManagedBy   = "terraform"
      Repository  = var.repository
    }
  }
}

# The Route 53 Domains API exists only in us-east-1, and a Route 53 query-log
# group must also be created there regardless of where the rest of the platform
# runs. Pinning both to an alias keeps aws_region free to change.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = var.project
      Environment = "shared"
      ManagedBy   = "terraform"
      Repository  = var.repository
    }
  }
}
