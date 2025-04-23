variable "vmrest_user" {
  description = "Username created by vmrest.exe --config"
  type        = string
  default     = "vmrest"
}

variable "vmrest_password" {
  description = "Password created by vmrest.exe --config"
  type        = string
}

variable "base_vm_id" {
  description = "ID of an existing VM to clone"
  type        = string
}

variable "vm_processors" {
  description = "Number of vCPUs for the new VM"
  type        = number
  default     = 2
}

variable "vm_memory" {
  description = "Memory (MB) for the new VM"
  type        = number
  default     = 2048
}

variable "vm_path" {
  description = "Filesystem path where the new VM will be created"
  type        = string
  default     = "C:\\Users\\<YourName>\\Documents\\Virtual Machines\\TestVM-Terraform"
}
