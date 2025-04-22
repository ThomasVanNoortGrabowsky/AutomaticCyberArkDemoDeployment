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
  url      = "http://127.0.0.1:8697/api"
}

resource "vmworkstation_vm" "test_vm" {
  sourceid     = var.base_vm_id
  denomination = "TestVM-Terraform"
  description  = "VM created via Terraform"
  processors   = var.vm_processors
  memory       = var.vm_memory
  path         = var.vm_path
}
