# variables.tf
variable "vmrest_user" { type = string }
variable "vmrest_pass" { type = string }
variable "template_id" { type = string }
variable "vm_processors" { type = number; default = 2 }
variable "vm_memory"     { type = number; default = 2048 }
variable "vm_path"       { type = string }
