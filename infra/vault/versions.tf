terraform {
  required_version = "= 1.17.1"

  backend "http" {}

  required_providers {
    vault = {
      source = "hashicorp/vault"
      version = "5.13.0"
    }
  }
}
