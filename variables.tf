variable "vmrest_user" {
  type    = string
  default = "vmrest"
}

variable "vmrest_password" {
  type    = string
  default = "Cyberark1"
}

variable "vault_image_id" {
  type = string
}

variable "app_image_id" {
  type = string
}

variable "vm_processors" {
  type    = number
  default = 2
}

variable "vm_memory" {
  type    = number
  default = 2048
}

variable "vm_path" {
  type    = string
  default = "C:\\Users\\ThomasvanNoort\\Documents\\Virtual Machines\\"
}
