# OTEL Metrics Export to Fly Managed Grafana

## Overview

Enable Claude Code's native OpenTelemetry telemetry and export metrics to Fly.io's managed Grafana system (fly-metrics.net) via an OTEL Collector sidecar process running inside the container.

The feature is **opt-in** and **disabled by default** -- it activates only when both `OTEL_FLY_TOKEN` and `OTEL_FLY_ORG` environment variables are set.

## Architecture

```
+--------------------------------------------------+
|  Claudetainer (Fly Machine)                      |
|                                                  |
|  +--------------+    OTLP/gRPC    +----------+   |
|  |  Claude Code  | ------------->  |  otelcol |   |
|  |              |  localhost:4317  |          |   |
|  +--------------+                 +-----+----+   |
|                                         |        |
+--------------------------------------------------+
                                          | Prometheus
                                          | remote-write
                                          v
                              fly-metrics.net/api/v1/
                              <org>/prometheus/api/v1/write
                                          |
                                          v
                                  Fly Managed Grafana
                                  (fly-metrics.net)
```

- Claude Code exports OTLP to `localhost:4317` (traffic never leaves the machine).
- `otelcol` receives OTLP, batches, and remote-writes to Fly's Prometheus endpoint.
- Only the **metrics pipeline** exports to Fly. The collector receives OTLP logs (events) from Claude Code but has no exporter configured for them -- they are silently dropped. This is a known limitation: per-tool-call events (`tool_result`), per-API-request cost breakdowns (`api_request`), and prompt events (`user_prompt`) are not available in Fly Grafana. A logs pipeline can be added later when a backend (Loki, ClickHouse, etc.) is available.

## Opt-in Mechanism

### User-provided environment variables

| Variable         | Required        | Purpose                                        |
| ---------------- | --------------- | ---------------------------------------------- |
| `OTEL_FLY_TOKEN` | Yes (to enable) | Fly API token for Prometheus remote-write auth |
| `OTEL_FLY_ORG`   | Yes (to enable) | Fly org slug for the metrics endpoint URL      |

### Internally set environment variables (when enabled)

| Variable                       | Value                   | Purpose                                                        |
| ------------------------------ | ----------------------- | -------------------------------------------------------------- |
| `CLAUDE_CODE_ENABLE_TELEMETRY` | `1`                     | Tells Claude Code to emit OTEL data                            |
| `OTEL_EXPORTER_OTLP_ENDPOINT`  | `http://127.0.0.1:4317` | Points Claude Code at the local collector                      |
| `OTEL_EXPORTER_OTLP_PROTOCOL`  | `grpc`                  | Protocol for OTLP export                                       |
| `OTEL_METRICS_EXPORTER`        | `otlp`                  | Export metrics via OTLP                                        |
| `OTEL_LOGS_EXPORTER`           | `otlp`                  | Export events (tool_result, api_request, user_prompt) via OTLP |

### Privacy controls (hardcoded OFF)

| Variable                | Value         | Rationale                                                        |
| ----------------------- | ------------- | ---------------------------------------------------------------- |
| `OTEL_LOG_USER_PROMPTS` | `0` (not set) | Prompt content should not leave the container                    |
| `OTEL_LOG_TOOL_DETAILS` | `0` (not set) | Tool arguments may contain file paths, URLs, or sensitive values |

These are intentionally not configurable. The security model assumes telemetry should contain aggregate metrics and event metadata, not content.

### Activation logic

```bash
if [ -n "$OTEL_FLY_TOKEN" ] && [ -n "$OTEL_FLY_ORG" ]; then
  # generate collector config, start otelcol, set Claude Code env vars
fi
```

When the variables are not set, no collector starts, no OTEL env vars are injected, and Claude Code behaves exactly as it does today.

## OTEL Collector Configuration

Config template at `/opt/otel/otelcol-config.yaml.template`, rendered at boot via `envsubst`:

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 127.0.0.1:4317

processors:
  batch:
    timeout: 30s
    send_batch_size: 1024

exporters:
  prometheusremotewrite:
    endpoint: "https://fly-metrics.net/api/v1/${OTEL_FLY_ORG}/prometheus/api/v1/write"
    headers:
      Authorization: "Bearer ${OTEL_FLY_TOKEN}"
    resource_to_telemetry_conversion:
      enabled: true

extensions:
  health_check:
    endpoint: 127.0.0.1:13133

service:
  extensions: [health_check]
  pipelines:
    metrics:
      receivers: [otlp]
      processors: [batch]
      exporters: [prometheusremotewrite]
```

Key decisions:

- **Metrics pipeline only** -- logs and traces have no backend in Fly's Prometheus system.
- **Batch processor** with 30s timeout balances freshness vs. network efficiency.
- **`resource_to_telemetry_conversion`** promotes OTEL resource attributes (`service.name`, `host.name`) to Prometheus labels for Grafana queryability.
- **Listens on `127.0.0.1` only** -- collector never accepts external traffic.

## What You Get in Grafana

### Available metrics (from Claude Code's native OTEL)

| Metric                                 | Type    | Description                                                                |
| -------------------------------------- | ------- | -------------------------------------------------------------------------- |
| `claude_code_cost_usage_USD_total`     | Counter | Cumulative cost in USD                                                     |
| `claude_code_token_usage_tokens_total` | Counter | Token usage, segmented by type (input, output, cache_creation, cache_read) |
| `claude_code_sessions`                 | Counter | Session count                                                              |

### Segmentation labels (via resource_to_telemetry_conversion)

Metrics can be filtered/grouped by: `model`, `app.version`, `session.id`, `user.account_uuid`, `organization.id`.

### What you do NOT get (until a logs backend is added)

- Per-tool-call breakdowns (tool name, success/failure, duration)
- Per-API-request cost and token detail
- Prompt-level correlation (which prompt triggered which costs)
- Tool argument details (file paths, commands)

These are exported as OTEL log records (events), not metrics. Fly's Prometheus backend cannot store them.

## Dockerfile Changes

- Download the `otelcol` binary (linux/amd64) from official GitHub releases.
- Place at `/usr/local/bin/otelcol`.
- Place the config template at `/opt/otel/otelcol-config.yaml.template`.
- Image size impact: ~50MB for the statically linked Go binary. No new runtime dependencies.

## Boot Sequence Integration

The OTEL setup slots into `entrypoint.sh` after network lockdown and before Claude Code settings copy:

1. Validate secrets
2. Mount tmpfs
3. Start CoreDNS
4. Apply iptables
5. **Start OTEL Collector (if enabled)**
6. Configure git/gh/npm auth
7. Copy Claude settings + set OTEL env vars (if enabled)
8. Remount rootfs read-only
9. Clone repo
10. Readiness checks (+ collector health check if enabled)

Why this position:

- Network must be up first (collector needs outbound to `fly-metrics.net`).
- Must happen before rootfs remount (config file is written to `/tmp/otel/`).
- Must happen before Claude Code settings so OTEL env vars can be injected.

Collector lifecycle:

- Started in a background loop with auto-restart (same pattern as CoreDNS).
- Config written to `/tmp/otel/otelcol-config.yaml` (tmpfs, writable).
- Logs to `/tmp/otel/otelcol.log`.
- Health check: `curl -s http://127.0.0.1:13133/` (collector's built-in health extension).

## Network and Security Changes

### Domain allowlist

Add `fly-metrics.net` to `network/domains.conf`.

### Approval rules

Add `OTEL_FLY_TOKEN` to Tier 2 hot-words in `approval/rules.conf` alongside existing credential variable names. Indirect references escalate to Haiku classification.

No Tier 1 hard-block needed -- the token is scoped to metrics write, lower value than `GH_PAT` or `CLAUDE_CODE_OAUTH_TOKEN`.

### Token isolation

- `OTEL_FLY_TOKEN` is read by `entrypoint.sh` (runs as root) and written into the collector config at `/tmp/otel/otelcol-config.yaml`.
- It is **not** exported into Claude Code's shell environment.
- The config file is owned by `claude` user (since otelcol runs as claude), so Claude Code could read it via `cat`. This is an accepted risk at the same exposure level as `.npmrc` which contains the GH_PAT for npm auth. The approval pipeline's Tier 2 escalation provides defense.

### Layer impact assessment

| Layer               | Impact                                                          |
| ------------------- | --------------------------------------------------------------- |
| Container Hardening | Minimal -- new binary, tmpfs-based config, no privilege changes |
| Network Isolation   | One new domain added to allowlist                               |
| Command Approval    | One new hot-word for credential protection                      |

## Testing and Validation

### Feature-off path

Deploy without `OTEL_FLY_TOKEN`/`OTEL_FLY_ORG`. Confirm: no collector process running, no OTEL env vars in Claude Code's environment, no behavior change.

### Feature-on path

Deploy with both vars set. Confirm: collector starts, health check passes at `:13133`, Claude Code has `CLAUDE_CODE_ENABLE_TELEMETRY=1` in its environment.

### Metrics flow

Run a Claude Code session, then check Fly Grafana for metrics appearing under the org's Prometheus data source.

### Collector resilience

Kill the collector process, confirm it auto-restarts via the background loop.

### Approval rule test

Add test case in `approval/__tests__/` for `OTEL_FLY_TOKEN` hot-word escalation.

### No automated integration test

The full pipeline requires a live Fly deployment with real credentials. Metrics flow validation is manual.
