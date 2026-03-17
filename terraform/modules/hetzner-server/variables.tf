variable "name" {
  description = "Server hostname"
  type        = string
}

variable "server_type" {
  description = "Hetzner server type (e.g. cx22, cpx31)"
  type        = string
}

variable "image" {
  description = "OS image name (e.g. debian-12, alma-9)"
  type        = string
}

variable "location" {
  description = "Hetzner datacenter location"
  type        = string
  default     = "ash"
}

variable "ssh_key_ids" {
  description = "List of Hetzner SSH key IDs"
  type        = list(number)
  default     = []
}

variable "firewall_ids" {
  description = "List of Hetzner firewall IDs to attach"
  type        = list(number)
  default     = []
}

variable "user_data" {
  description = "cloud-init user_data script"
  type        = string
  default     = null
}

variable "labels" {
  description = "Map of labels to attach to the server"
  type        = map(string)
  default     = {}
}
