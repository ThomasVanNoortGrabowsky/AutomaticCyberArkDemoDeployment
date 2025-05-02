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
  password = var.vmrest_pass
  url      = "http://127.0.0.1:8697"
  https    = false
  debug    = false
}

resource "vmworkstation_vm" "vault" {
  sourceid     = var.template_id
  denomination = "Vault-VM"
  linked_clone = true
  processors   = var.vm_processors
  memory       = var.vm_memory
  path         = var.vm_path
}

resource "vmworkstation_vm" "pvwa" {
  sourceid     = var.template_id
  denomination = "PVWA-VM"
  depends_on   = [vmworkstation_vm.vault]
  linked_clone = true
  processors   = var.vm_processors
  memory       = var.vm_memory
  path         = var.vm_path
}

resource "vmworkstation_vm" "psm" {
  sourceid     = var.template_id
  denomination = "PSM-VM"
  depends_on   = [vmworkstation_vm.pvwa]
  linked_clone = true
  processors   = var.vm_processors
  memory       = var.vm_memory
  path         = var.vm_path
}

resource "vmworkstation_vm" "cpm" {
  sourceid     = var.template_id
  denomination = "CPM-VM"
  depends_on   = [vmworkstation_vm.psm]
  linked_clone = true
  processors   = var.vm_processors
  memory       = var.vm_memory
  path         = var.vm_path
}
