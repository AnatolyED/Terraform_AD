terraform {
  required_version = "= 1.17.1"

  backend "http" {}

  required_providers {
    ad = {
      source = "isometry/ad"
      version = "0.5.0"
    }
  }
}
