variable "vmrest_user" {
  type        = string
  description = "VMREST username"
}

variable "vmrest_pass" {
  type        = string
  description = "VMREST password"
  sensitive   = true
}

variable "template_id" {
  type        = string
  description = "GUID of the Win2022_GUI template VM"
}

variable "vm_processors" {
  type        = number
  description = "Number of vCPUs for each demo VM"
  default     = 2
}

variable "vm_memory" {
  type        = number
  description = "Memory (MB) for each demo VM"
  default     = 2048
}

variable "vm_path" {
  type        = string
  description = "Filesystem path where the new VMs will be placed"
}
