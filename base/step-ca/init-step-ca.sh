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

# run_step_ca_init CONFIG_DIR CA_NAME DNS_NAMES PROVISIONER_NAME \
#   PROVISIONER_PASSWORD_FILE ROOT_CRT ROOT_KEY ROOT_PASSWORD_FILE \
#   SERVER_CA_CRT SERVER_CA_KEY
#
# Initializes a standalone step-ca PKI under CONFIG_DIR using the provided
# root certificate/key, with PROVISIONER_NAME as the sole provisioner
# created at init time. DNS_NAMES is a comma-separated list of DNS names
# (or IPs) for the CA itself.
#
# Deliberately omits `step ca init --acme`: that flag creates its own
# "acme" provisioner as a side effect, which would collide with a
# caller-chosen name/count of ACME provisioners added later via
# add_acme_provisioner. ACME support is layered on separately by that
# function instead, keeping PROVISIONER_NAME the only provisioner this
# function creates.
#
# `step ca init` always generates an EC P-256 intermediate, even when given
# an RSA --root/--key: there is no flag to control the intermediate's key
# type. Dell iDRAC 8 requires every certificate in its trust chain -
# including the intermediate - to be RSA, so after init we replace the
# generated intermediate with the pre-built RSA intermediate given by
# SERVER_CA_CRT/SERVER_CA_KEY (the officially documented way to bring your
# own intermediate: https://smallstep.com/docs/tutorials/intermediate-ca-new-ca/).
run_step_ca_init() {
  local config_dir="$1"
  local ca_name="$2"
  local dns_names="$3"
  local provisioner_name="$4"
  local provisioner_password_file="$5"
  local root_crt="$6"
  local root_key="$7"
  local root_password_file="$8"
  local server_ca_crt="$9"
  local server_ca_key="${10}"
  local -a dns_args=()
  local -a dns_list=()
  local name

  IFS=',' read -r -a dns_list <<<"$dns_names"
  for name in "${dns_list[@]}"; do
    dns_args+=(--dns="$name")
  done

  STEPPATH="$config_dir" step ca init \
    --deployment-type=standalone \
    --name="$ca_name" \
    --address=:9000 \
    --provisioner="$provisioner_name" \
    --password-file="$provisioner_password_file" \
    --provisioner-password-file="$provisioner_password_file" \
    --root="$root_crt" \
    --key="$root_key" \
    --key-password-file="$root_password_file" \
    "${dns_args[@]}" || return 1

  cp "$server_ca_crt" "$config_dir/certs/intermediate_ca.crt" || return 1
  cp "$server_ca_key" "$config_dir/secrets/intermediate_ca_key" || return 1
}

# add_idrac_provisioner CA_CONFIG NAME PASSWORD_FILE TEMPLATE_PATH
#
# Adds a JWK provisioner named NAME to the ca.json at CA_CONFIG, then
# attaches the x509 certificate template at TEMPLATE_PATH to it (used to
# enforce RSA-only, iDRAC-compatible certificates).
add_idrac_provisioner() {
  local ca_config="$1"
  local name="$2"
  local password_file="$3"
  local template_path="$4"
  local step_path

  step_path="$(dirname "$(dirname "$ca_config")")"

  STEPPATH="$step_path" step ca provisioner add "$name" \
    --type=JWK --create --password-file="$password_file" \
    --ca-config="$ca_config" || return 1
  STEPPATH="$step_path" step ca provisioner update "$name" \
    --x509-template="$template_path" \
    --ca-config="$ca_config" || return 1
}

# add_acme_provisioner CA_CONFIG NAME
#
# Adds an ACME provisioner named NAME to the ca.json at CA_CONFIG.
add_acme_provisioner() {
  local ca_config="$1"
  local name="$2"
  local step_path

  step_path="$(dirname "$(dirname "$ca_config")")"

  STEPPATH="$step_path" step ca provisioner add "$name" \
    --type=ACME \
    --ca-config="$ca_config" || return 1
}

main() {
  :
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
