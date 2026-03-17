# ============================================================
# Helix Stax Infrastructure — Root Module
# Phase 1: CP Server (existing) + Services VPS (new)
# ============================================================

# ---- CP Firewall (existing — imported) ----------------------
module "cp_firewall" {
  source = "./modules/hetzner-firewall"

  name = "helix-cp-firewall"

  rules = [
    {
      direction   = "in"
      protocol    = "tcp"
      port        = "80"
      source_ips  = ["0.0.0.0/0", "::/0"]
      description = "HTTP"
    },
    {
      direction   = "in"
      protocol    = "tcp"
      port        = "443"
      source_ips  = ["0.0.0.0/0", "::/0"]
      description = "HTTPS"
    },
    {
      direction   = "in"
      protocol    = "udp"
      port        = "8472"
      source_ips  = ["138.201.131.157/32"]
      description = "Flannel-VXLAN-worker"
    },
    {
      direction   = "in"
      protocol    = "tcp"
      port        = "10250"
      source_ips  = ["138.201.131.157/32"]
      description = "Kubelet-worker"
    },
    {
      direction   = "in"
      protocol    = "tcp"
      port        = "6443"
      source_ips  = [var.admin_ip]
      description = "K8s-API-admin"
    },
    {
      direction   = "in"
      protocol    = "tcp"
      port        = "6443"
      source_ips  = ["138.201.131.157/32"]
      description = "K8s-API-worker"
    },
    {
      direction   = "in"
      protocol    = "tcp"
      port        = "2379-2380"
      source_ips  = ["178.156.233.12/32"]
      description = "etcd-self"
    },
    {
      direction   = "in"
      protocol    = "tcp"
      port        = "30000-32767"
      source_ips  = [var.admin_ip]
      description = "NodePort-admin"
    },
    {
      direction   = "in"
      protocol    = "tcp"
      port        = tostring(var.ssh_port)
      source_ips  = [var.admin_ip]
      description = "SSH-admin"
    },
  ]
}

# ---- CP Server (existing — imported) ------------------------
module "cp_server" {
  source = "./modules/hetzner-server"

  name        = "helix-stax-cp"
  server_type = var.cp_server_type
  image       = var.cp_image
  location    = var.location
  ssh_key_ids = var.ssh_key_ids
  firewall_ids = [module.cp_firewall.firewall_id]

  # No cloud-init on import — server is already configured
  user_data = null

  labels = {}
}

# ---- VPS Firewall (new) -------------------------------------
module "vps_firewall" {
  source = "./modules/hetzner-firewall"

  name = "helix-vps-firewall"

  rules = [
    {
      direction   = "in"
      protocol    = "tcp"
      port        = tostring(var.ssh_port)
      source_ips  = [var.admin_ip]
      description = "SSH-admin"
    },
    {
      direction   = "in"
      protocol    = "tcp"
      port        = "80"
      source_ips  = ["0.0.0.0/0", "::/0"]
      description = "HTTP"
    },
    {
      direction   = "in"
      protocol    = "tcp"
      port        = "443"
      source_ips  = ["0.0.0.0/0", "::/0"]
      description = "HTTPS"
    },
  ]
}

# ---- Services VPS (new) -------------------------------------
module "vps_server" {
  source = "./modules/hetzner-server"

  name        = "helix-stax-vps"
  server_type = var.vps_server_type
  image       = var.vps_image
  location    = var.location
  ssh_key_ids = var.ssh_key_ids
  firewall_ids = [module.vps_firewall.firewall_id]

  user_data = templatefile("${path.module}/cloud-init/vps-init.yaml", {
    ssh_port = var.ssh_port
  })

  labels = {
    role = "services"
  }
}
