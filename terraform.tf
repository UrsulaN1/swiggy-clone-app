
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.20.0" # Using '~>' is a best practice to allow minor patch updates
    }
  }
}

provider "aws" {
  region = "us-east-1"
}