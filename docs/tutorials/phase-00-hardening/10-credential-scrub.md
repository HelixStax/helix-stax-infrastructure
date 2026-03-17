---
tags: [infrastructure, hardening, credentials, security, phase-0, tutorial-series, helix-stax]
created: 2026-03-17
updated: 2026-03-17
status: draft
author: Ezra (Security Engineer)
estimated-time: 15-20 minutes
applies-to: [local-workstation]
---

# 10 — Credential Scrub

> Remove all plaintext credentials from memory files and documentation. Since K3s is being wiped, ALL cluster credentials are automatically invalidated. New credentials will be generated fresh and stored properly from Day 1.
>
> **Run on**: Local workstation (not the servers)
> **Estimated time**: 15-20 minutes

---

## Prerequisites

- Access to the local filesystem where memory files are stored
- Understanding that K3s wipe (Phase 0, Task 1) invalidates ALL existing cluster credentials
- No need to rotate credentials on the servers — they are being wiped

---

## Tutorial Notes

> **Content capture**: This is a great "what NOT to do" tutorial moment. Show the plaintext passwords in the memory file (blurred/redacted in video), explain why this is dangerous, then show the scrub. Talk about the secrets management strategy for Day 1 (OpenBao in Phase 2).

---

## Context: Why This Matters

The file `infrastructure_k3s.md` contains plaintext passwords for:
- **Devtron admin** dashboard
- **ArgoCD admin** account
- **ArgoCD devtron** service account

These were stored in a Claude memory file for convenience during initial setup. This is a security anti-pattern:
- Anyone with filesystem access can read them
- They persist across sessions and could be synced/backed up
- They violate the "no plaintext credentials" security policy

**The good news**: Since we are wiping K3s entirely (fresh install), every single one of these credentials is dead. They will stop working the moment `k3s-uninstall.sh` runs. We just need to clean up the evidence.

---

## Step 1: Identify Files with Plaintext Credentials

### Known files

| File | Contains | Status |
|------|----------|--------|
| `~/.claude/projects/C--Users-MSI-LAPTOP/memory/infrastructure_k3s.md` | Devtron password, ArgoCD passwords | **SCRUB** |

### Search for other files

On your local workstation, search for potential credential leaks:

```bash
# Search memory files for common credential patterns
grep -rn -i "password\|passwd\|secret\|token\|api.key\|credential" \
  ~/.claude/projects/C--Users-MSI-LAPTOP/memory/ \
  2>/dev/null | grep -v "ROTATED\|OpenBao\|Phase 2\|stored in"
```

```bash
# Search helix-stax-secrets directory
ls -la ~/.claude/helix-stax-secrets/ 2>/dev/null
```

Review any matches and add them to the scrub list.

---

## Step 2: Document What Exists (Before Scrub)

Before scrubbing, document what credentials exist so we know what needs to be regenerated:

| Credential | Old Value | Source | Regeneration Plan |
|------------|-----------|--------|-------------------|
| Devtron admin password | `WC95pufhdcz-2enB` | infrastructure_k3s.md, line 38 | Fresh install generates new password (Phase 9) |
| ArgoCD admin password | `n6BRV-Dyodo9yqC6` | infrastructure_k3s.md, line 39 | Fresh install generates new password (Phase 9) |
| ArgoCD devtron account password | `cZum5TmSk906MOO8` | infrastructure_k3s.md, line 40 | Fresh install generates new password (Phase 9) |

> [!WARNING]
> The table above contains the actual old passwords for documentation purposes. After the K3s wipe, these are completely dead. Do NOT reuse them.

---

## Step 3: Scrub infrastructure_k3s.md

Edit `~/.claude/projects/C--Users-MSI-LAPTOP/memory/infrastructure_k3s.md`.

### Before (lines 37-41):

```
## Devtron Credentials (POST-REINSTALL 2026-03-10)
- Devtron admin password: `WC95pufhdcz-2enB`
- ArgoCD admin password: `n6BRV-Dyodo9yqC6`
- ArgoCD devtron account password: `cZum5TmSk906MOO8`
- NodePort: **31656** (changed from 31379)
```

### After (replace with):

```
## Devtron Credentials
- Devtron admin password: [ROTATED — invalidated by K3s wipe, regenerated in Phase 9]
- ArgoCD admin password: [ROTATED — invalidated by K3s wipe, regenerated in Phase 9]
- ArgoCD devtron account password: [ROTATED — invalidated by K3s wipe, regenerated in Phase 9]
- NodePort: TBD (assigned during Phase 9 fresh install)
```

### How to apply

**Option A: Manual edit**

Open the file in your editor and make the replacements above.

**Option B: sed (Unix/Git Bash)**

```bash
MEMFILE="$HOME/.claude/projects/C--Users-MSI-LAPTOP/memory/infrastructure_k3s.md"

# Replace each credential line
sed -i 's/Devtron admin password: `WC95pufhdcz-2enB`/Devtron admin password: [ROTATED — invalidated by K3s wipe, regenerated in Phase 9]/' "$MEMFILE"
sed -i 's/ArgoCD admin password: `n6BRV-Dyodo9yqC6`/ArgoCD admin password: [ROTATED — invalidated by K3s wipe, regenerated in Phase 9]/' "$MEMFILE"
sed -i 's/ArgoCD devtron account password: `cZum5TmSk906MOO8`/ArgoCD devtron account password: [ROTATED — invalidated by K3s wipe, regenerated in Phase 9]/' "$MEMFILE"
sed -i 's/NodePort: \*\*31656\*\* (changed from 31379)/NodePort: TBD (assigned during Phase 9 fresh install)/' "$MEMFILE"

# Update the section header
sed -i 's/## Devtron Credentials (POST-REINSTALL 2026-03-10)/## Devtron Credentials/' "$MEMFILE"
```

---

## Step 4: Update Devtron State Section

Also update the "Devtron State" section to reflect the upcoming wipe:

### Before:

```
## Devtron State
- Fully reinstalled and working (2026-03-10)
- `isCdArgoSetup: true` confirmed
...
```

### After:

```
## Devtron State
- WIPED as part of Phase 0 clean install (2026-03-17)
- Will be reinstalled fresh in Phase 9 pointing at CloudNativePG
- All previous state (ArgoCD config, chart store, pipelines) is gone
- New installation will use OpenBao for credential storage from Day 1
```

---

## Step 5: Verify the Scrub

```bash
MEMFILE="$HOME/.claude/projects/C--Users-MSI-LAPTOP/memory/infrastructure_k3s.md"

echo "=== Credential Scrub Verification ==="

echo "--- Searching for known credential patterns ---"
grep -n "WC95pufhdcz" "$MEMFILE" && echo "FAIL: Devtron password still present!" || echo "PASS: Devtron password scrubbed"
grep -n "n6BRV-Dyodo" "$MEMFILE" && echo "FAIL: ArgoCD admin password still present!" || echo "PASS: ArgoCD admin password scrubbed"
grep -n "cZum5TmSk90" "$MEMFILE" && echo "FAIL: ArgoCD devtron password still present!" || echo "PASS: ArgoCD devtron password scrubbed"

echo ""
echo "--- Searching for any remaining password-like values ---"
grep -n "password:" "$MEMFILE" | grep -v "ROTATED\|OpenBao\|Phase"
if [ $? -eq 0 ]; then
    echo "WARNING: Found password lines that may need review"
else
    echo "PASS: No unscrubbed password lines found"
fi

echo ""
echo "--- Current credential section ---"
grep -A 5 "## Devtron Credentials" "$MEMFILE"
```

---

## Step 6: Check helix-stax-secrets Directory

```bash
echo "=== Secrets Directory ==="
ls -la ~/.claude/helix-stax-secrets/ 2>/dev/null

# If kubeconfig exists, it will be invalidated by the K3s wipe
if [ -f ~/.claude/helix-stax-secrets/kubeconfig ]; then
    echo ""
    echo "WARNING: kubeconfig exists. It will be invalid after K3s wipe."
    echo "A new kubeconfig will be generated during Phase 1 K3s install."
    echo "Consider renaming: mv kubeconfig kubeconfig.old.$(date +%Y%m%d)"
fi
```

---

## Step 7: Future Credential Strategy

After Phase 0, the credential lifecycle changes permanently:

```
Phase 0-1 (Before OpenBao):
  Generate credential → Store in local encrypted file only
  → NEVER in memory files, docs, or chat

Phase 2+ (After OpenBao):
  Generate credential → Store in OpenBao immediately
  → External Secrets Operator syncs to K8s secrets
  → Apps read from K8s secrets
  → Human access via Vaultwarden (personal password manager)
```

### What to store where

| Item | Where | NOT Here |
|------|-------|----------|
| K8s kubeconfig | `~/.claude/helix-stax-secrets/kubeconfig` | Memory files |
| Service passwords | OpenBao (Phase 2+) | Memory files, docs, chat |
| SSH keys | `~/.ssh/helixstax_key` | Memory files |
| API tokens | OpenBao (Phase 2+) | Memory files, docs, chat |
| Reference (name only) | Memory files | Actual values |

---

## Rollback Plan

This scrub is intentionally non-reversible. The old credentials are:
1. **Dead** — K3s wipe invalidates them
2. **Documented** — Step 2 above records what existed for regeneration planning
3. **Not needed** — Fresh install generates everything new

If you somehow need the old values before the wipe, they exist in git history of the memory file (if it was ever committed) or in this document's Step 2 table.

> [!WARNING]
> After completing this scrub, these old credentials should NEVER be reused even if they appear to work temporarily. Treat them as compromised.

## Execution Log

### Issue 1: Three Plaintext Passwords in Memory Files
- **What happened**: File `infrastructure_k3s.md` contained plaintext passwords for Devtron admin, ArgoCD admin, and ArgoCD devtron account from previous installation.
- **Root cause**: Passwords were stored in memory file for convenience during initial setup (anti-pattern, but necessary for early phases before secrets management was available).
- **Fix applied**: Replaced all three passwords with `[ROTATED — invalidated by K3s wipe, regenerated in Phase 9]` markers. Updated Devtron State section to reflect wipe and Phase 9 reinstall plan.
- **Lesson for readers**: Never store plaintext passwords in documentation, memory files, or chat. From Phase 1 onward, store all credentials in encrypted storage (OpenBao in Phase 2, local encrypted file until then). Treat memory files as reference only, not credential storage.

### Issue 2: kubeconfig Will Become Invalid After K3s Wipe
- **What happened**: File `~/.claude/helix-stax-secrets/kubeconfig` exists in the secrets directory. It will be invalid once K3s is wiped.
- **Root cause**: kubeconfig contains cluster certificates and server endpoints specific to the running cluster. Wiping K3s invalidates all certificates.
- **Fix applied**: No action taken pre-wipe. Documented that a new kubeconfig will be generated in Phase 1 after K3s reinstall. Suggested renaming old kubeconfig to kubeconfig.old.YYYYMMDD for reference.
- **Lesson for readers**: After a cluster wipe, all cluster-specific files (kubeconfig, certificates, tokens) become invalid. Don't attempt to reuse them. Generate fresh from the new cluster.

### Issue 3: Secrets Directory Organization is Appropriate
- **What happened**: Verification found that `~/.claude/helix-stax-secrets/` directory contains multiple credential files (.env, secrets.yaml, vault-init-keys.json, rescue-passwords.txt), properly separated from memory files.
- **Root cause**: This is correct practice — dedicated encrypted directory for secrets, separate from memory files (which are for reference only).
- **Fix applied**: No action needed. This organization follows best practices. Keep secrets in dedicated directory, never in memory/doc files.
- **Lesson for readers**: Create a dedicated directory for all credentials (e.g., `~/.claude/PROJECT-secrets/`) with restricted permissions. Keep memory files reference-only. Once OpenBao is available (Phase 2), migrate secrets there instead.

## Deviations from Guide
- **No deviations**: Guide procedure was followed exactly. All three passwords scrubbed, Devtron State updated, kubeconfig old-format identified, secrets directory verified as appropriate location.
