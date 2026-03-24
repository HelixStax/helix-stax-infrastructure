# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-03-24

### Added

- OpenTofu configuration rewritten for current architecture (Hetzner + Cloudflare providers)
- Test server module (cpx11, temporary validation server)
- Cloud-init template for AlmaLinux 9 (minimal — user + SSH key only)
- `tofu-apply.sh` — vault-backed OpenTofu wrapper (secrets from Cloudflare vault)
- 29 Gemini deep research prompts covering full infrastructure stack
- 28 research outputs generated via OpenRouter (Gemini 2.5 Pro)
- Ansible hardening architecture design (lockout prevention strategy)
- Trunk linting config (gitleaks, shellcheck, yamllint, checkov, tflint, markdownlint)
- Pre-commit hook with gitleaks (blocks secrets in commits)
- OpenRouter research script (`scripts/gemini-research-openrouter.sh`)
- 14 Architecture Decision Records (ADRs 002-014)
- Security policies (20+ policy documents)
- Compliance docs (hardening control mapping, security incident reports)
- Ansible hardening design doc with CrowdSec + dev-sec integration
- `.trunk/trunk.yaml` for IDE linting
- OpenTofu `.gitignore` (state files, tfvars, plans)
- Secrets-vault Cloudflare Worker converted to MCP server

### Changed

- OpenTofu: removed Hetzner firewalls (Cloudflare + CrowdSec handle security)
- OpenTofu: VPS image changed from `debian-12` to `alma-9`
- OpenTofu: server types corrected to `cpx31`
- OpenTofu: test server type `cx22` → `cpx11` (cx22 removed from Hetzner)
- All research prompts: fixed stale IPs (138.201.131.157 → 5.78.145.30)
- All research prompts: fixed Traefik CRD API version (containo.us → traefik.io)
- All research prompts: fixed Zitadel domain (.com → .net for internal)
- All research prompts: removed cert-manager/Let's Encrypt refs (Cloudflare Origin CA)
- All research outputs: 326 security fixes applied across 26 files
- Hetzner API token rotated (old one was in plaintext tfvars)

### Removed

- `docker-compose/` directory (Authentik, NetBird, nginx, homepage, etc.)
- Hetzner firewall modules (replaced by Cloudflare edge + CrowdSec host IDS)
- Stale cloud-init files (`vps-init.yaml`, `vps-init-v2.yaml`)
- Stale Cloudflare zero-trust setup scripts (exposed service token IDs)
- Old `terraform/` directory (replaced by `opentofu/`)
- Trivy MCP server (npm package compromised — v0.69.4 malicious)
- Cilium CNI research (dropped — Flannel sufficient for current scale)

### Security

- Rotated Hetzner Cloud API token (was in plaintext `terraform.tfvars`)
- Removed hardcoded admin IP from OpenTofu variable defaults
- SSH hardening uses sshd_config.d drop-in (not fragile sed)
- VXLAN port 8472 restricted to cluster node IPs only
- Added ssh_key_ids validation (prevents empty-list lockout)
- SELinux enforcing verification in cloud-init
- Pre-commit gitleaks hook installed
- Trivy MCP removed after second npm supply chain compromise

## [0.1.0] - 2026-03-06

### Added

- Initial infrastructure repo structure
- OpenTofu modules for Hetzner server + firewall
- Basic Helm chart values
- K3s deployment docs
- Identity/Edge Infrastructure sprint (48 files)
