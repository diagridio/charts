terraform {
  # Cross-variable validation (postgresql_version against
  # postgresql_replicate_source_db_arn) landed in 1.9.
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.97"
    }
    # Stamps each RDS incarnation's final-snapshot name so a rebuilt database
    # does not collide with the snapshot its predecessor left behind.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}
