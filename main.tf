terraform {
  required_providers {
    vmworkstation = {
      source  = "elsudano/vmworkstation"
      version = "1.1.6"
    }
  }
}

provider "vmworkstation" {
  user     = var.vmrest_user
  password = var.vmrest_password
  url      = "http://127.0.0.1:8697"    # no /api
  https    = false
  debug    = true
}

# Vault
resource "vmworkstation_vm" "vault" {
  sourceid     = var.vault_image_id
  denomination = "Vault-VM"
  description  = "CyberArk Vault"
  processors   = var.vm_processors
  memory       = var.vm_memory
  path         = var.vm_path
}

# PVWA
resource "vmworkstation_vm" "pvwa" {
  sourceid     = var.app_image_id
  denomination = "PVWA-VM"
  description  = "CyberArk PVWA"
  processors   = var.vm_processors
  memory       = var.vm_memory
  path         = var.vm_path
}

# PSM
resource "vmworkstation_vm" "psm" {
  sourceid     = var.app_image_id
  denomination = "PSM-VM"
  description  = "CyberArk PSM"
  processors   = var.vm_processors
  memory       = var.vm_memory
  path         = var.vm_path
}

# CPM
resource "vmworkstation_vm" "cpm" {
  sourceid     = var.app_image_id
  denomination = "CPM-VM"
  description  = "CyberArk CPM"
  processors   = var.vm_processors
  memory       = var.vm_memory
  path         = var.vm_path
}
