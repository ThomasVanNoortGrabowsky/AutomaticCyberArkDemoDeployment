terraform {
  required_providers {
    vmworkstation = {
      source  = "elsudano/vmworkstation"
      version = "1.0.4"
    }
  }
}

provider "vmworkstation" {
  user     = var.vmrest_user
  password = var.vmrest_password
  url      = "http://127.0.0.1:8697"   # no /api suffix :contentReference[oaicite:7]{index=7}
  https    = false
  debug    = true
}

resource "vmworkstation_vm" "vault" {
  sourceid     = var.vault_image_id
  denomination = "Vault-VM"
  processors   = var.vm_processors
  memory       = var.vm_memory
  path         = var.vm_path
}

resource "vmworkstation_vm" "pvwa" {
  sourceid     = var.app_image_id
  denomination = "PVWA-VM"
  depends_on   = [vmworkstation_vm.vault]
  processors   = var.vm_processors
  memory       = var.vm_memory
  path         = var.vm_path
}

resource "vmworkstation_vm" "psm" {
  sourceid     = var.app_image_id
  denomination = "PSM-VM"
  depends_on   = [vmworkstation_vm.pvwa]
  processors   = var.vm_processors
  memory       = var.vm_memory
  path         = var.vm_path
}

resource "vmworkstation_vm" "cpm" {
  sourceid     = var.app_image_id
  denomination = "CPM-VM"
  depends_on   = [vmworkstation_vm.psm]
  processors   = var.vm_processors
  memory       = var.vm_memory
  path         = var.vm_path
}
