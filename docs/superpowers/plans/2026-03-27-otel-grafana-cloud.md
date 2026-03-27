# OTEL Grafana Cloud Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable Claude Code's native OTEL telemetry (metrics + events) to export directly to Grafana Cloud via OTLP push, activated by three operator-provided env vars.

**Architecture:** Two-phase activation in `entrypoint.sh` — Phase 1 extracts the OTLP gateway hostname and injects it into CoreDNS + iptables before network setup; Phase 2 exports the OTEL env vars before Claude Code launches. No new binaries, no Dockerfile changes.

**Tech Stack:** Bash (entrypoint), TypeScript/Bun (approval tests), CoreDNS config generation, iptables rules

**Spec:** `docs/superpowers/specs/2026-03-27-otel-metrics-design.md`

---

## File Structure

| File                               | Action | Responsibility                                                             |
| ---------------------------------- | ------ | -------------------------------------------------------------------------- |
| `approval/rules.conf`              | Modify | Add Tier 1 block + Tier 2 hot-words for Grafana credentials                |
| `approval/__tests__/tiers.test.ts` | Modify | Add test cases for new block/hot-word rules                                |
| `scripts/refresh-iptables.sh`      | Modify | Read optional `/tmp/extra-domains.conf` in addition to static domains file |
| `scripts/entrypoint.sh`            | Modify | Two-phase OTEL activation (hostname extraction + env var export)           |

No new files are created. All changes are modifications to existing files.

---

### Task 1: Approval Rules — Credential Protection

**Files:**

- Modify: `approval/rules.conf:70-71` (Tier 1 block-pattern for credential vars)
- Modify: `approval/rules.conf:98-101` (Tier 2 hot-words for credential names)
- Modify: `approval/__tests__/tiers.test.ts:81-85` (Tier 1 blocked test cases)
- Modify: `approval/__tests__/tiers.test.ts:148-151` (Tier 2 escalated test cases)

- [ ] **Step 1: Write failing tests for Tier 1 blocks**

Add Grafana credential direct references to the `blocked` array in `approval/__tests__/tiers.test.ts`, after the existing credential variable tests (after line 85):

```typescript
    "echo $GRAFANA_API_TOKEN",
    "echo ${GRAFANA_INSTANCE_ID}",
```

- [ ] **Step 2: Write failing tests for Tier 2 hot-words**

Add Grafana credential names and OTLP headers to the `escalated` array in `approval/__tests__/tiers.test.ts`, after the existing credential hot-word tests (after line 151):

```typescript
    "echo GRAFANA_API_TOKEN",
    "echo GRAFANA_INSTANCE_ID",
    "echo OTEL_EXPORTER_OTLP_HEADERS",
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd approval && bun test`
Expected: 5 new test failures — 2 Tier 1 blocks and 3 Tier 2 escalations not yet in rules.conf.

- [ ] **Step 4: Add Tier 1 block-pattern to rules.conf**

In `approval/rules.conf`, modify the existing credential block-pattern on line 71 to include the Grafana variables. Change:

```conf
block-pattern:\$\{?(CLAUDE_CODE_OAUTH_TOKEN|GH_PAT|FLY_ACCESS_TOKEN|FLY_API_TOKEN)\b
```

to:

```conf
block-pattern:\$\{?(CLAUDE_CODE_OAUTH_TOKEN|GH_PAT|FLY_ACCESS_TOKEN|FLY_API_TOKEN|GRAFANA_API_TOKEN|GRAFANA_INSTANCE_ID)\b
```

- [ ] **Step 5: Add Tier 2 hot-words to rules.conf**

Append the following lines at the end of `approval/rules.conf`, after the existing `hot:.fly/` line:

```conf

# Grafana Cloud credential variables
hot:GRAFANA_API_TOKEN
hot:GRAFANA_INSTANCE_ID
hot:OTEL_EXPORTER_OTLP_HEADERS
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd approval && bun test`
Expected: All tests pass, including the 5 new test cases.

- [ ] **Step 7: Format and commit**

```bash
bunx prettier --write "approval/__tests__/tiers.test.ts"
git add approval/rules.conf approval/__tests__/tiers.test.ts
git commit -m "feat(approval): protect Grafana Cloud credentials in block and hot-word rules"
```

---

### Task 2: iptables — Support Dynamic Extra Domains

**Files:**

- Modify: `scripts/refresh-iptables.sh:4` (add supplementary domains file support)

The iptables refresh script currently reads only `/opt/network/domains.conf` (read-only rootfs). It needs to also read an optional `/tmp/extra-domains.conf` file so the entrypoint can dynamically add the Grafana OTLP gateway hostname.

- [ ] **Step 1: Modify refresh-iptables.sh to read supplementary domains**

In `scripts/refresh-iptables.sh`, after the existing domain loop (after line 34), add a second loop that reads from an optional extra domains file. Add after the `done < "$DOMAINS_FILE"` line:

```bash

# Read optional supplementary domains (e.g., dynamically added by entrypoint)
EXTRA_DOMAINS_FILE="/tmp/extra-domains.conf"
if [[ -f "$EXTRA_DOMAINS_FILE" ]]; then
  while IFS= read -r domain || [[ -n "$domain" ]]; do
    [[ "$domain" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$domain" ]] && continue
    domain=$(echo "$domain" | tr -d '[:space:]')

    ips=$(dig +short "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
    for ip in $ips; do
      echo "-A OUTPUT -d $ip -j ACCEPT" >> "$RULES_FILE"
    done
  done < "$EXTRA_DOMAINS_FILE"
fi
```

- [ ] **Step 2: Verify the script is syntactically valid**

Run: `bash -n scripts/refresh-iptables.sh`
Expected: No output (no syntax errors).

- [ ] **Step 3: Commit**

```bash
git add scripts/refresh-iptables.sh
git commit -m "feat(network): support supplementary domains file for dynamic iptables rules"
```

---

### Task 3: Entrypoint — Two-Phase OTEL Activation

**Files:**

- Modify: `scripts/entrypoint.sh:59` (Phase 1: hostname extraction + CoreDNS/iptables injection, before network setup)
- Modify: `scripts/entrypoint.sh:131` (Phase 2: OTEL env var export, before Claude Code setup)

This is the core change. The entrypoint gets two new blocks:

**Phase 1** runs before CoreDNS config generation (before line 62). It extracts the hostname from `GRAFANA_OTLP_ENDPOINT` and writes it to `/tmp/extra-domains.conf` (picked up by iptables) and appends a CoreDNS forward zone to the Corefile.

**Phase 2** runs after git/gh/npm auth (after line 129, before Claude Code setup). It exports the OTEL env vars.

- [ ] **Step 1: Add Phase 1 — hostname extraction and network setup**

In `scripts/entrypoint.sh`, add the following block immediately after the `# === 2. Network lockdown ===` comment (line 59) and before the CoreDNS config generation (line 62):

```bash

# OTEL Phase 1: Extract Grafana Cloud hostname for network allowlisting
# (Phase 2 exports the OTEL env vars later, after network setup is complete)
if [[ -n "${GRAFANA_INSTANCE_ID:-}" ]] && [[ -n "${GRAFANA_API_TOKEN:-}" ]] && [[ -n "${GRAFANA_OTLP_ENDPOINT:-}" ]]; then
  GRAFANA_HOST=$(echo "$GRAFANA_OTLP_ENDPOINT" | sed 's|https\?://||' | cut -d/ -f1 | cut -d: -f1)
  echo "[ENTRYPOINT] OTEL: will allow outbound to $GRAFANA_HOST"
  # Write to supplementary domains file for iptables refresh script
  echo "$GRAFANA_HOST" > /tmp/extra-domains.conf
fi

```

- [ ] **Step 2: Add Grafana host to CoreDNS config generation**

The existing CoreDNS domain loop (lines 65-81) reads from `/opt/network/domains.conf`. After this loop ends (`done < /opt/network/domains.conf`), add a block that appends the Grafana host zone if `GRAFANA_HOST` was set. Add immediately after the `done < /opt/network/domains.conf` line:

```bash

# Append Grafana Cloud OTLP gateway domain (if OTEL is enabled)
if [[ -n "${GRAFANA_HOST:-}" ]]; then
  cat >> "$COREFILE" <<EOF

${GRAFANA_HOST} {
    bind 127.0.0.53
    template IN AAAA {
        rcode NOERROR
    }
    forward . 8.8.8.8 1.1.1.1
    log
    cache 300
}
EOF
fi
```

- [ ] **Step 3: Add Phase 2 — OTEL env var export**

In `scripts/entrypoint.sh`, add the following block after the npm/bun auth section (after line 129, the `chmod 644 /home/claude/.npmrc` line) and before the `# === 4. Claude Code setup ===` comment:

```bash

# OTEL Phase 2: Export telemetry env vars (network is now configured)
if [[ -n "${GRAFANA_HOST:-}" ]]; then
  export CLAUDE_CODE_ENABLE_TELEMETRY=1
  export OTEL_METRICS_EXPORTER=otlp
  export OTEL_LOGS_EXPORTER=otlp
  export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
  export OTEL_EXPORTER_OTLP_ENDPOINT="$GRAFANA_OTLP_ENDPOINT"
  export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic $(echo -n "${GRAFANA_INSTANCE_ID}:${GRAFANA_API_TOKEN}" | base64 -w 0)"
  export OTEL_LOG_USER_PROMPTS="${OTEL_LOG_USER_PROMPTS:-1}"
  export OTEL_LOG_TOOL_DETAILS="${OTEL_LOG_TOOL_DETAILS:-1}"
  echo "[ENTRYPOINT] OTEL telemetry enabled → ${GRAFANA_OTLP_ENDPOINT}"
fi

```

- [ ] **Step 4: Verify the script is syntactically valid**

Run: `bash -n scripts/entrypoint.sh`
Expected: No output (no syntax errors).

- [ ] **Step 5: Commit**

```bash
git add scripts/entrypoint.sh
git commit -m "feat(entrypoint): two-phase OTEL activation for Grafana Cloud export"
```

---

### Task 4: Documentation — Update Boot Sequence in CLAUDE.md

**Files:**

- Modify: `CLAUDE.md` (boot sequence section)

- [ ] **Step 1: Update boot sequence in CLAUDE.md**

In `CLAUDE.md`, find the `### Boot Sequence` section and update the numbered list to reflect the new steps. Change:

```
1. Validate secrets
2. Mount tmpfs (filesystem hardening)
3. Start CoreDNS (DNS filtering)
4. Apply iptables (network isolation)
5. Configure git/gh/npm auth (credential setup)
6. Copy Claude settings
7. Remount rootfs read-only
8. Clone repo
9. Readiness checks
```

to:

```
1. Validate secrets
2. Mount tmpfs (filesystem hardening)
3. Extract Grafana OTLP hostname (if credentials set)
4. Start CoreDNS (DNS filtering, with Grafana host if set)
5. Apply iptables (network isolation, with Grafana host if set)
6. Configure git/gh/npm auth (credential setup)
7. Export OTEL env vars (if Grafana credentials set)
8. Copy Claude settings
9. Remount rootfs read-only
10. Clone repo
11. Readiness checks
```

- [ ] **Step 2: Format and commit**

```bash
bunx prettier --write "CLAUDE.md"
git add CLAUDE.md
git commit -m "docs: update boot sequence to reflect OTEL activation phases"
```

---

### Task 5: Final Verification

- [ ] **Step 1: Run full approval test suite**

Run: `cd approval && bun test`
Expected: All tests pass.

- [ ] **Step 2: Run prettier check on all modified files**

Run: `bunx prettier --check "**/*.{ts,md}"`
Expected: All files pass formatting check.

- [ ] **Step 3: Verify entrypoint syntax**

Run: `bash -n scripts/entrypoint.sh && bash -n scripts/refresh-iptables.sh`
Expected: No output (no syntax errors in either script).

- [ ] **Step 4: Review the complete diff**

Run: `git log --oneline main..HEAD` and `git diff main..HEAD --stat`
Expected: 4 new commits modifying:

- `approval/rules.conf` — Grafana credential protection
- `approval/__tests__/tiers.test.ts` — test cases for new rules
- `scripts/refresh-iptables.sh` — supplementary domains support
- `scripts/entrypoint.sh` — two-phase OTEL activation
- `CLAUDE.md` — updated boot sequence
