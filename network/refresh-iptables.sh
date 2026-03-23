#!/usr/bin/env bash
set -euo pipefail

DOMAINS_FILE="/opt/network/domains.conf"
RULES_FILE=$(mktemp)

cat > "$RULES_FILE" <<'HEADER'
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT DROP [0:0]
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -d 169.254.0.0/16 -j DROP
-A OUTPUT -d 172.16.0.0/12 -j DROP
-A OUTPUT -p udp -d 127.0.0.53 --dport 53 -j ACCEPT
-A OUTPUT -p tcp -d 127.0.0.53 --dport 53 -j ACCEPT
-A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
HEADER

while IFS= read -r domain || [[ -n "$domain" ]]; do
  [[ "$domain" =~ ^[[:space:]]*# ]] && continue
  [[ -z "$domain" ]] && continue
  domain=$(echo "$domain" | tr -d '[:space:]')

  ips=$(dig +short "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
  for ip in $ips; do
    echo "-A OUTPUT -d $ip -j ACCEPT" >> "$RULES_FILE"
  done
done < "$DOMAINS_FILE"

echo "-A OUTPUT -p udp -j DROP" >> "$RULES_FILE"
echo '-A OUTPUT -j NFLOG --nflog-prefix "CLAUDETAINER_DROP" --nflog-group 100' >> "$RULES_FILE"
echo "COMMIT" >> "$RULES_FILE"

iptables-restore < "$RULES_FILE"

# IPv6 rules: use ip6tables-restore for atomic application (no window where
# policy is DROP but rules are flushed, which would kill active SSH sessions)
ip6tables-restore 2>/dev/null <<'IP6RULES' || true
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT DROP [0:0]
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -d fdaa::/16 -j ACCEPT
-A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
COMMIT
IP6RULES

rm -f "$RULES_FILE"
echo "[NETWORK] iptables refreshed at $(date)" >&2
