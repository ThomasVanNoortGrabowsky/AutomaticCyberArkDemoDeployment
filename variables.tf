variable "vmrest_user" {
  description = "Username for vmrest API"
  type        = string
  default     = "vmrest"
}

variable "vmrest_password" {
  description = "Password for vmrest API"
  type        = string
}

variable "vault_image_id" {
  description = "ID of the Vault golden VM image"
  type        = string
}

variable "app_image_id" {
  description = "ID of the golden image for PVWA/CPM/PSM"
  type        = string
}

variable "vm_processors" {
  description = "Number of vCPUs"
  type        = number
  default     = 2
}

variable "vm_memory" {
  description = "Memory in MB"
  type        = number
  default     = 2048
}

variable "vm_path" {
  description = "Path for the new VM"
  type        = string
  default     = "C:\\Users\\<YourName>\\Documents\\Virtual Machines\\TestVM-Terraform"
}
