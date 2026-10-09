terraform {
  required_version = ">= 1.7.0"

  backend "azurerm" {}

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.13"
    }
  }
}

provider "azapi" {}
