terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.30"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 1.15"
    }
  }
}
