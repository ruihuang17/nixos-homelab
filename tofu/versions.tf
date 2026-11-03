terraform {
  required_version = ">= 1.8"

  required_providers {
    ovh = {
      source  = "ovh/ovh"
      version = "~> 2.5"
    }
  }
}

# Credentials and endpoint come from the environment (see README.md):
#   OVH_ENDPOINT, OVH_APPLICATION_KEY, OVH_APPLICATION_SECRET, OVH_CONSUMER_KEY
provider "ovh" {}
