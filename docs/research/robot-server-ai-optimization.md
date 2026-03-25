# Robot Server AI Optimization — Research

**Server**: Hetzner Robot dedicated at 138.201.131.157
**Role**: K3s AI worker node (CPU-only, no GPU)
**OS target**: AlmaLinux 9.7
**Date**: 2025-03-25
**Status**: Research — input for Architect phase

---

## 1. CPU Inference Optimization

### Instruction Set Detection

Before tuning, confirm what instruction sets the CPU supports:

```bash
grep -o 'avx[^ ]*' /proc/cpuinfo | sort -u
# or
lscpu | grep -i avx
```

Key flags to look for:
- `avx2` — available on most Hetzner Robot CPUs (Haswell / 2013+). Doubles FP throughput vs SSE4.
- `avx512f` — present on Skylake-SP, Cascade Lake, Ice Lake server CPUs. Doubles register width again.
- `avx_vnni` — integer dot-product acceleration (Alder Lake+, Zen 5). Speeds Q4/Q8 quantized matmul.
- `amx_int8` / `amx_bf16` — tile-based matrix engine, Sapphire Rapids+. llama.cpp supports it.

### Build Flags for llama.cpp

llama.cpp detects capabilities at runtime by default when using pre-built Ollama binaries. For a manual build targeting a known CPU:

```bash
# AVX2 only (safe baseline for Haswell+)
cmake -B build -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON

# AVX-512 (Skylake-SP / Cascade Lake)
cmake -B build -DGGML_AVX512=ON -DGGML_AVX512_VBMI=ON -DGGML_AVX512_VNNI=ON

# AMX (Sapphire Rapids+)
cmake -B build -DGGML_AMX_INT8=ON -DGGML_AMX_BF16=ON
```

OpenBLAS can replace llama.cpp's internal BLAS for prompt evaluation on some hardware, but
llama.cpp's native GGML kernels outperform it for token generation. Leave OpenBLAS disabled
unless you have specific benchmarks showing otherwise.

### Quantization Selection for CPU

| Format | Size (7B) | RAM (7B) | Quality loss | Speed on AVX2 | Recommendation |
|--------|-----------|----------|--------------|----------------|----------------|
| Q4_K_M | ~4.1 GB | ~5.5 GB | Minimal | Fastest | **Default choice** — best quality/speed/RAM tradeoff |
| Q5_K_M | ~4.8 GB | ~6.2 GB | Near-zero | Fast | Use when RAM allows and reasoning quality matters |
| Q8_0 | ~7.2 GB | ~9 GB | Negligible | Moderate | Use for critical tasks; 2x RAM vs Q4_K_M |
| F16 | ~14 GB | ~16 GB | None | Slow | Avoid on CPU; only if embedding accuracy required |
| Q4_0 | ~3.8 GB | ~5 GB | Moderate | Fastest | Fallback when RAM is very tight |
| IQ4_NL | ~4.1 GB | ~5.5 GB | Low | Fast | Newer imatrix quant; better than Q4_0 at same size |

**Rule of thumb**:
- 7B models: Q4_K_M. Fits in 8 GB RAM, good throughput.
- 13B models: Q4_K_M (fits ~8 GB) or Q5_K_M (fits ~10 GB).
- 30B models: Q4_K_M (~18 GB) — requires 32+ GB RAM.
- 70B models: Q4_K_M (~40 GB) — requires 64+ GB RAM. CPU-only is slow (~1 tok/s).

**K-quants (K_M, K_S, K_L)** use mixed quantization where attention and feed-forward layers
are quantized at different bitwidths. K_M is the recommended middle tier. K_S saves ~10% RAM
at small quality cost; K_L is rarely worth the extra RAM.

**Source**: arXiv 2601.14277 unified quantization evaluation confirms Q4_K_M / Q5_K_M as the
dominant Pareto-optimal choices on CPU for Llama 3.1 8B class models.

---

## 2. RAM Tuning

### RAM Requirements by Model Size

| Model | Q4_K_M RAM | Q5_K_M RAM | Q8_0 RAM | Notes |
|-------|-----------|-----------|---------|-------|
| 7B | 5.5 GB | 6.2 GB | 9 GB | Context window adds ~0.5 GB per 4K tokens |
| 13B | 8.5 GB | 10 GB | 15 GB | |
| 30B | 18 GB | 22 GB | 32 GB | 32 GB system RAM minimum |
| 70B | 40 GB | 48 GB | 70 GB | 64 GB system RAM minimum; ~1 tok/s |

Context memory: `(n_ctx * n_layers * head_dim * 2 * 2 bytes)` — approximately 0.5 GB per 4K
context for 7B, scaling linearly with context length and model size.

### Huge Pages

Huge pages reduce TLB pressure during large matrix loads. For AI inference:

```bash
# Check current huge page allocation
grep Huge /proc/meminfo

# Allocate 2 MB huge pages at runtime (loses effect after reboot)
echo 4096 > /proc/sys/vm/nr_hugepages   # 4096 * 2MB = 8 GB reserved

# Persist across reboots via /etc/sysctl.d/
cat > /etc/sysctl.d/99-hugepages.conf << 'EOF'
vm.nr_hugepages = 4096
vm.hugetlb_shm_group = 0
EOF
sysctl -p /etc/sysctl.d/99-hugepages.conf
```

Boot-time allocation is more reliable than runtime (less fragmentation). Add to GRUB cmdline:

```
hugepagesz=2M hugepages=4096
```

llama.cpp uses `mmap()` for model files — transparent huge pages (THP) will apply automatically
when `CONFIG_TRANSPARENT_HUGEPAGE=y` (default in RHEL/AlmaLinux kernels). Enable THP:

```bash
echo always > /sys/kernel/mm/transparent_hugepage/enabled
# or 'madvise' to let llama.cpp opt-in selectively
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
```

### NUMA Awareness

Hetzner Robot servers with dual-socket CPUs have NUMA topology. Check:

```bash
numactl --hardware
lscpu | grep -i numa
```

If NUMA nodes > 1, pin Ollama to one node to avoid cross-node memory latency:

```bash
numactl --cpunodebind=0 --membind=0 ollama serve
```

For single-socket servers (common in Hetzner Robot AX line): NUMA is irrelevant.

### Swap and zram

**zram**: Compressed RAM block device. Useful when model barely exceeds physical RAM:

```bash
# AlmaLinux 9 — zram-generator is available
dnf install zram-generator
cat > /etc/systemd/zram-generator.conf << 'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = lz4
EOF
systemctl daemon-reload
systemctl start systemd-zram-setup@zram0.service
```

**Swap tuning**: Minimize swappiness to keep model weights in RAM:

```bash
echo 'vm.swappiness = 10' >> /etc/sysctl.d/99-ai.conf
sysctl -p /etc/sysctl.d/99-ai.conf
```

Do not rely on disk swap for active inference — latency becomes unacceptable (10-100x slower).
zram-backed swap is acceptable for brief spikes; NVMe swap is last resort only.

---

## 3. Ollama CPU Configuration

### Environment Variables

Set these in `/etc/systemd/system/ollama.service.d/override.conf` (or the K3s deployment env):

```ini
[Service]
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_NUM_THREADS=0"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_KEEP_ALIVE=30m"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_HOST=0.0.0.0:11434"
```

| Variable | Recommended | Notes |
|----------|-------------|-------|
| `OLLAMA_NUM_PARALLEL` | `1` | CPU-only: parallel requests fragment RAM and slow each other. Set to 1 unless request volume demands otherwise. |
| `OLLAMA_NUM_THREADS` | `0` | 0 = auto-detect (uses all physical cores). Set explicitly to physical core count if needed: e.g., `16`. |
| `OLLAMA_MAX_LOADED_MODELS` | `1` | Load one model at a time on CPU to prevent OOM. |
| `OLLAMA_KEEP_ALIVE` | `30m` | Keep model loaded between requests. `0` = unload immediately. `-1` = never unload. For dedicated AI node, use `24h`. |
| `OLLAMA_FLASH_ATTENTION` | `1` | Reduces KV cache memory. Enable. |
| `OLLAMA_MAX_QUEUE` | `10` | Reject excess requests rather than queuing indefinitely. Prevents runaway memory. |

### Thread Count

Ollama defers to llama.cpp which uses OpenMP. The default (0 = auto) maps to logical cores
including hyperthreads. For AI inference, physical cores outperform hyperthreaded logical cores:

```bash
# Get physical core count
lscpu | grep "Core(s) per socket"

# Set OLLAMA_NUM_THREADS to physical cores
# e.g., for a 16-core CPU: OLLAMA_NUM_THREADS=16
```

Hyperthreading hurts inference throughput because both threads share execution units and L1/L2
cache. Disabling SMT in BIOS or limiting thread count to physical cores typically yields 10-20%
faster token generation.

### Model Preloading

Preload a model at Ollama startup via a one-shot API call in the systemd service:

```bash
# In ExecStartPost or a separate oneshot service:
curl -s http://localhost:11434/api/generate \
  -d '{"model":"llama3.2:3b-instruct-q4_K_M","keep_alive":"24h","prompt":""}' \
  > /dev/null
```

Or use the `/api/chat` endpoint with an empty messages array to load without generating tokens.

### Modelfile for CPU Tuning

Create a custom Modelfile to set inference parameters:

```
FROM llama3.2:3b-instruct-q4_K_M

PARAMETER num_ctx 4096
PARAMETER num_thread 16
PARAMETER num_batch 512
PARAMETER num_predict -1
```

`num_batch` controls prompt eval batch size. Larger values (512-1024) are faster for long
prompts but use more RAM. On CPU, 256-512 is a safe range.

---

## 4. GPU Rental Services (Burst/Overflow Capacity)

For tasks that exceed CPU inference capability (70B models, real-time latency requirements),
use GPU rental APIs as overflow. Call from n8n workflows.

### Provider Comparison (2026 pricing)

| Provider | Model | $/hr | API style | Latency | Best for |
|----------|-------|------|-----------|---------|----------|
| **Vast.ai** | A100 80GB | ~$1.49-$1.87 | REST + CLI | Variable (marketplace) | Cost-sensitive batch tasks |
| **Vast.ai** | H100 80GB | ~$1.87-$2.50 | REST + CLI | Variable | Large model experimentation |
| **RunPod** | A100 80GB | ~$1.74 | REST + GraphQL | Consistent | Production-adjacent workloads |
| **RunPod** | H100 80GB | ~$1.99 | REST + GraphQL | Consistent | Reliable burst inference |
| **Lambda Labs** | H100 80GB | ~$2.99 | REST (OpenAI-compatible) | Low | Simple integration, OpenAI API drop-in |
| **Lambda Labs** | A100 40GB | ~$1.29 | REST (OpenAI-compatible) | Low | Affordable mid-size |

Pricing fluctuates. Check live: [vast.ai/pricing](https://vast.ai/pricing) and
[runpod.io](https://www.runpod.io).

### API Summary

**Vast.ai**
- Marketplace REST API + CLI (`vastai`)
- Instance lifecycle: `vastai create instance <offer_id> --image <docker_image>`
- OpenAI-compatible endpoints available via deployed containers
- Auth: API key via `X-API-Key` header
- No managed inference API — you deploy your own container (e.g., `ollama/ollama` or `vllm`)
- Docs: `https://vast.ai/docs/`

**RunPod**
- Serverless inference API (no instance management needed) + pod deployment
- Serverless endpoint: `POST https://api.runpod.ai/v2/{endpoint_id}/run`
- Auth: `Authorization: Bearer <API_KEY>`
- OpenAI-compatible via RunPod Workers (vLLM, ollama workers available)
- GraphQL API for pod management
- Docs: `https://docs.runpod.io`

**Lambda Labs**
- Fully managed, OpenAI-compatible API
- Base URL: `https://api.lambdalabs.com/v1`
- Auth: `Authorization: Bearer <API_KEY>`
- Drop-in replacement for OpenAI SDK — change base URL and key
- Docs: `https://docs.lambdalabs.com/`

### Calling GPU Rental from n8n

The simplest integration is Lambda Labs (OpenAI-compatible). Use the existing HTTP Request node:

```json
{
  "method": "POST",
  "url": "https://api.lambdalabs.com/v1/chat/completions",
  "headers": {
    "Authorization": "Bearer {{ $env.LAMBDA_API_KEY }}",
    "Content-Type": "application/json"
  },
  "body": {
    "model": "llama-3.1-70b-instruct-fp8",
    "messages": [{ "role": "user", "content": "{{ $json.prompt }}" }],
    "max_tokens": 2048
  }
}
```

For RunPod Serverless (async pattern):

```json
// Step 1: Submit job
POST https://api.runpod.ai/v2/{endpoint_id}/run
Authorization: Bearer {{ $env.RUNPOD_API_KEY }}
{ "input": { "prompt": "{{ $json.prompt }}", "max_new_tokens": 512 } }

// Returns: { "id": "job-abc123", "status": "IN_QUEUE" }

// Step 2: Poll for result (n8n Wait node + HTTP Request)
GET https://api.runpod.io/v2/{endpoint_id}/status/job-abc123
```

Use n8n's **If** node to route requests: short prompts / small models go to local Ollama;
large models or low-latency requirements go to GPU rental endpoint. Store API keys in n8n
credential store (not environment variables directly).

---

## 5. Storage Tuning

### NVMe vs HDD for Model Files

| Aspect | NVMe SSD | HDD |
|--------|----------|-----|
| Sequential read | 3,000-7,000 MB/s | 100-200 MB/s |
| Model load time (7B Q4_K_M, ~4 GB) | <2 seconds | 20-40 seconds |
| Token generation | No impact (model in RAM) | No impact once loaded |
| Concurrent model swaps | Fast | Painful |
| Cost on Hetzner Robot | Included on AX line | Included on standard |

**Use NVMe whenever available.** Model load time on HDD (20-40 seconds per swap) is the
primary bottleneck for multi-model deployments. Once a model is in RAM, storage speed
no longer affects inference.

### Filesystem Selection

| Filesystem | Seq read throughput | Large file support | Recommended |
|------------|--------------------|--------------------|-------------|
| XFS | Excellent | Excellent (default for RHEL/AlmaLinux) | **Yes — use XFS** |
| ext4 | Good | Good (files up to 16 TB) | Acceptable |
| Btrfs | Good | Good + snapshots | Adds complexity, not needed |

XFS is the AlmaLinux 9 default and is preferred for large sequential files (model weights).
It allocates in extents and avoids fragmentation better than ext4 for large files.

**Mount options for model storage partition:**

```fstab
/dev/nvme0n1p2  /var/lib/ollama  xfs  defaults,noatime,nodiratime  0 2
```

`noatime` eliminates access-time writes on every model file read — measurable improvement
for mmap-heavy workloads.

### Model Storage Layout

```
/var/lib/ollama/           # Ollama model store (default)
  models/
    blobs/                 # Raw GGUF blobs
    manifests/             # Model metadata

/var/lib/ollama-cache/     # Optional: separate fast NVMe for active models
```

If the server has both NVMe and HDD, put active models on NVMe and archive models on HDD.
Symlink `~/.ollama` or set `OLLAMA_MODELS` env var to the NVMe path.

---

## 6. Hetzner Robot Server Management

### Fresh OS Install — Robot Panel Flow

Hetzner Robot dedicated servers do NOT have a cloud API for reinstalls. All provisioning
goes through the Robot web panel at `https://robot.hetzner.com`.

**Steps for fresh AlmaLinux 9.7 install:**

1. Log in to `https://robot.hetzner.com`
2. Navigate to **Servers** > select server (138.201.131.157)
3. Go to the **Linux** tab
4. Select **AlmaLinux 9** from the OS dropdown
   - If AlmaLinux 9.7 is not listed, use the closest available or proceed via rescue system
5. Configure partitioning (recommended for AI workloads — see below)
6. Set SSH public key
7. Click **Activate rescue system** and then trigger install via SSH into rescue

**Rescue system install (more control):**

```bash
# 1. Activate Hetzner rescue system via Robot panel (Linux tab > Rescue)
# 2. SSH into rescue system:
ssh root@138.201.131.157   # uses temporary rescue credentials shown in panel

# 3. Run installimage:
installimage

# 4. Edit the config file that opens:
DRIVE1 /dev/sda        # or nvme0n1
SWRAID 0
BOOTLOADER grub
HOSTNAME helix-worker-ai
PART /boot ext4 1G
PART lvm vg0 all

LV vg0 root / xfs 50G
LV vg0 var /var xfs 200G
LV vg0 ollama /var/lib/ollama xfs all   # remaining space for models

IMAGE /root/.oldroot/nfs/images/AlmaLinux-93-amd64-base.tar.gz
```

Save and exit. `installimage` runs unattended; server reboots into fresh AlmaLinux.

### IPMI / KVM Console Access

IPMI is available on Hetzner Robot servers that have integrated BMC (out-of-band management).

**Checking IPMI availability:**
- Robot panel > Server > **KVM** tab. If BMC is present, options appear.
- Not all Hetzner Robot servers have IPMI — depends on server model (EX line typically does).

**Ordering KVM console:**
1. Robot panel > Servers > select server > **Support** tab
2. Choose **Remote Console / KVM**
3. Provide a time window. Free for 3 hours; additional 3-hour blocks cost €8.40 ex-VAT.
4. If you need to attach an ISO, include download URL in comments — Hetzner technicians
   will download it and create a bootable USB.

**IPMI direct access** (if server has dedicated IPMI port):

```bash
# Install ipmitool on local machine
dnf install ipmitool   # or apt install ipmitool

# Requires ordering dedicated IP for IPMI via Robot panel first
ipmitool -I lanplus -H <ipmi-ip> -U ADMIN -P <password> chassis status
ipmitool -I lanplus -H <ipmi-ip> -U ADMIN -P <password> sol activate
```

**VKVM** (Virtual KVM via browser): Available for servers with iDRAC / iLO equivalent.
Access via Robot panel once ordered. Requires Java or HTML5 viewer depending on BMC version.

### Post-Install Baseline (AlmaLinux 9.7)

After OS install, before joining K3s:

```bash
# Update and baseline packages
dnf update -y
dnf install -y epel-release
dnf install -y htop iotop numactl sysstat lsof wget curl git vim

# Disable unnecessary services
systemctl disable --now firewalld   # Traefik / k3s handles ingress
# Keep SELinux enforcing (CIS Level 1 requirement)
sestatus

# Verify CPU flags
lscpu | grep -E "avx|sse"

# Check NUMA topology
numactl --hardware

# Check storage layout
lsblk
df -hT
```

---

## 7. K3s Integration Notes

When joining this server as a K3s AI worker node, label it appropriately so workloads
schedule correctly:

```bash
# On control plane (heart):
kubectl label node helix-worker-ai \
  node-role.kubernetes.io/ai-worker=true \
  accelerator=cpu-only \
  workload-type=inference

# Taint to prevent non-AI workloads from landing here:
kubectl taint node helix-worker-ai \
  dedicated=ai:NoSchedule
```

Ollama Helm chart values should include node affinity:

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: workload-type
          operator: In
          values: [inference]
tolerations:
- key: dedicated
  operator: Equal
  value: ai
  effect: NoSchedule
```

---

## 8. Recommended Configuration Summary

| Setting | Value | Rationale |
|---------|-------|-----------|
| Quantization (7B/13B) | Q4_K_M | Best quality/RAM/speed tradeoff on CPU |
| Quantization (critical tasks) | Q5_K_M | Near-zero quality loss when RAM allows |
| Filesystem | XFS + noatime | AlmaLinux default, best for large files |
| Huge pages | THP = madvise | Transparent, no manual reservation needed |
| Swappiness | 10 | Keep model weights in RAM |
| zram | ram/2, lz4 | Compressed RAM swap for overflow |
| OLLAMA_NUM_PARALLEL | 1 | CPU-only: no benefit from parallelism |
| OLLAMA_NUM_THREADS | physical core count | Skip hyperthreads |
| OLLAMA_MAX_LOADED_MODELS | 1 | Prevent OOM from model stacking |
| OLLAMA_KEEP_ALIVE | 24h (dedicated node) | Avoid reload latency |
| GPU burst provider | Lambda Labs | OpenAI-compatible, simplest n8n integration |
| NUMA pinning | If dual-socket only | numactl --cpunodebind=0 --membind=0 |

---

## Sources

- [llama.cpp quantization evaluation — arXiv 2601.14277](https://arxiv.org/html/2601.14277v1)
- [llama.cpp GitHub — ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp)
- [Ollama FAQ — environment variables](https://docs.ollama.com/faq)
- [Ollama parallel request handling — glukhov.org](https://www.glukhov.org/post/2025/05/how-ollama-handles-parallel-requests/)
- [H100 rental price comparison 2026 — IntuitionLabs](https://intuitionlabs.ai/articles/h100-rental-prices-cloud-comparison)
- [Vast.ai vs RunPod pricing 2026 — Medium](https://medium.com/@velinxs/vast-ai-vs-runpod-pricing-in-2026-which-gpu-cloud-is-cheaper-bd4104aa591b)
- [Hetzner Robot KVM Console docs](https://docs.hetzner.com/robot/dedicated-server/maintenance/kvm-console/)
- [Hetzner Robot IPMI docs](https://docs.hetzner.com/robot/dedicated-server/maintenance/ipmi/)
- [Hetzner installing custom images](https://docs.hetzner.com/robot/dedicated-server/operating-systems/installing-custom-images/)
- [OS-level challenges in LLM inference — eunomia.dev](https://eunomia.dev/blog/2025/02/18/os-level-challenges-in-llm-inference-and-optimizations/)
- [NUMA binding, HugePages, kernel tuning — zmto.com](https://zmto.com/blog/ai-inference-latency-optimization)
- [Red Hat RHEL 8 huge pages config](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/8/html/monitoring_and_managing_system_status_and_performance/configuring-huge-pages_monitoring-and-managing-system-status-and-performance)
