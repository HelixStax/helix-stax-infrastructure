variable "hcloud_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

variable "ssh_key_ids" {
  description = "List of Hetzner SSH key IDs to attach to servers"
  type        = list(number)
}

variable "location" {
  description = "Hetzner datacenter location (e.g. ash, nbg1, fsn1)"
  type        = string
  default     = "ash"
}

variable "ssh_port" {
  description = "Custom SSH port used on all servers"
  type        = number
  default     = 2222
}

variable "admin_ip" {
  description = "Admin public IP allowed through firewalls (CIDR)"
  type        = string
  default     = "173.40.165.150/32"
}

variable "cp_server_type" {
  description = "Server type for the K3s control plane"
  type        = string
  default     = "cpx31"
}

variable "vps_server_type" {
  description = "Server type for the services VPS"
  type        = string
  default     = "cpx11"
}

variable "cp_image" {
  description = "OS image for the K3s control plane"
  type        = string
  default     = "alma-9"
}

variable "vps_image" {
  description = "OS image for the services VPS"
  type        = string
  default     = "debian-12"
}
