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
  url      = "http://127.0.0.1:8697/api"  # include /api so client hits the correct path
  https    = false                         # explicit for plain HTTP
  debug    = true                          # optional, enables verbose logs
}

resource "vmworkstation_vm" "test_vm" {
  sourceid     = var.vault_image_id       # uses the Vault golden image ID
  denomination = "TestVM-Terraform"
  description  = "VM created via Terraform"
  processors   = var.vm_processors
  memory       = var.vm_memory
  path         = var.vm_path
}
