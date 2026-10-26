#!/bin/bash

# apply_authority_policy CA_CONFIG ALLOW_DNS ALLOW_IP DEFAULT_DURATION
#
# Sets the authority-level SAN allow lists and default TLS certificate
# duration in the ca.json at CA_CONFIG. Keys are assigned, not appended,
# so re-running produces the same result.
apply_authority_policy() {
  local ca_config="$1"
  local allow_dns="$2"
  local allow_ip="$3"
  local default_duration="$4"
  local tmp

  tmp="$(mktemp "${ca_config}.XXXXXX")" || return 1
  if jq \
    --arg dns "$allow_dns" \
    --arg ip "$allow_ip" \
    --arg duration "$default_duration" \
    '.authority.policy.x509.allow.dns = [$dns]
     | .authority.policy.x509.allow.ip = [$ip]
     | .authority.claims.defaultTLSCertDuration = $duration' \
    "$ca_config" >"$tmp"; then
    mv "$tmp" "$ca_config"
  else
    rm -f "$tmp"
    return 1
  fi
}

main() {
  :
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
