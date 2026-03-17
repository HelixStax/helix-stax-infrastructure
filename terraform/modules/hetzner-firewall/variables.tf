variable "name" {
  description = "Firewall name"
  type        = string
}

variable "labels" {
  description = "Map of labels to attach to the firewall"
  type        = map(string)
  default     = {}
}

variable "rules" {
  description = "List of firewall rules"
  type = list(object({
    direction        = string
    protocol         = string
    port             = optional(string)
    source_ips       = optional(list(string), [])
    destination_ips  = optional(list(string), [])
    description      = optional(string)
  }))
  default = []
}
