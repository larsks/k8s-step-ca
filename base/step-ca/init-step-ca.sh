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

# ca_already_initialized CONFIG_DIR
#
# Returns 0 if a ca.json already exists under CONFIG_DIR (i.e. step ca
# init has already run against this STEPPATH), 1 otherwise. Callers use
# this to short-circuit before touching any secrets.
ca_already_initialized() {
  local config_dir="$1"

  [[ -f "$config_dir/config/ca.json" ]]
}

# fetch_kubectl WORKDIR
#
# Downloads the current stable `kubectl` release into WORKDIR and prints
# its path. Mirrors bootstrap-ca.sh's install-into-workdir technique, but
# never installs over a system binary: callers get back a path to use
# directly, so this script never depends on (or risks colliding with) a
# `kubectl` already on PATH.
fetch_kubectl() {
  local workdir="$1"
  local kubectl_version
  local kubectl_path="$workdir/kubectl"

  mkdir -p "$workdir" || return 1
  kubectl_version="$(curl -sL https://dl.k8s.io/release/stable.txt)" || return 1
  curl -sLo "$kubectl_path" "https://dl.k8s.io/release/${kubectl_version}/bin/linux/amd64/kubectl" || return 1
  chmod +x "$kubectl_path" || return 1
  echo "$kubectl_path"
}

# secret_field KUBECTL NAMESPACE SECRET FIELD WORKDIR
#
# Prints the decoded value of FIELD from SECRET in NAMESPACE, using
# KUBECTL (a path to a kubectl binary). Returns non-zero if the secret or
# the field doesn't exist, without printing anything.
secret_field() {
  local kubectl_bin="$1"
  local namespace="$2"
  local secret="$3"
  local field="$4"
  local workdir="$5"
  local encoded_file

  mkdir -p "$workdir" || return 1
  encoded_file="$(mktemp "$workdir/secret_field.XXXXXX")" || return 1

  if ! "$kubectl_bin" -n "$namespace" get secret "$secret" \
    -o go-template="{{index .data \"$field\"}}" >"$encoded_file" 2>/dev/null; then
    rm -f "$encoded_file"
    return 1
  fi
  if [[ ! -s "$encoded_file" ]]; then
    rm -f "$encoded_file"
    return 1
  fi

  base64 -d <"$encoded_file"
  rm -f "$encoded_file"
}

# apply_tls_secret KUBECTL NAMESPACE NAME CRT KEY
#
# Applies a kubernetes.io/tls Secret named NAME containing CRT/KEY as
# tls.crt/tls.key.
apply_tls_secret() {
  local kubectl_bin="$1"
  local namespace="$2"
  local name="$3"
  local crt="$4"
  local key="$5"

  cat <<EOF | "$kubectl_bin" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: $name
  namespace: $namespace
type: kubernetes.io/tls
data:
  tls.crt: $(base64 -w0 <"$crt")
  tls.key: $(base64 -w0 <"$key")
EOF
}

# apply_opaque_secret KUBECTL NAMESPACE NAME FIELD FILE
#
# Applies an Opaque Secret named NAME containing a single FIELD key whose
# value is the content of FILE.
apply_opaque_secret() {
  local kubectl_bin="$1"
  local namespace="$2"
  local name="$3"
  local field="$4"
  local file="$5"

  cat <<EOF | "$kubectl_bin" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: $name
  namespace: $namespace
type: Opaque
data:
  $field: $(base64 -w0 <"$file")
EOF
}

# ensure_server_ca KUBECTL NAMESPACE WORKDIR ROOT_CRT ROOT_KEY ROOT_PASSWORD_FILE
#
# Ensures a step-server-ca Secret exists, generating (and applying) an
# unencrypted RSA intermediate signed by ROOT_CRT/ROOT_KEY if it's
# absent. Either way, prints "CRT_PATH:KEY_PATH" for the caller to pass
# straight to run_step_ca_init: newly generated material under WORKDIR,
# or the well-known mount point of the optional step-server-ca Secret
# volume (see base/step-ca/deployment.yaml) if it already exists.
ensure_server_ca() {
  local kubectl_bin="$1"
  local namespace="$2"
  local workdir="$3"
  local root_crt="$4"
  local root_key="$5"
  local root_password_file="$6"
  local mounted_crt="/step/server-ca/tls.crt"
  local mounted_key="/step/server-ca/tls.key"

  mkdir -p "$workdir" || return 1

  if secret_field "$kubectl_bin" "$namespace" step-server-ca tls.crt "$workdir" >/dev/null; then
    echo "$mounted_crt:$mounted_key"
    return 0
  fi

  step certificate create "step-ca Server CA" \
    "$workdir/server_ca.crt" "$workdir/server_ca.key" \
    --profile intermediate-ca \
    --ca "$root_crt" --ca-key "$root_key" --ca-password-file "$root_password_file" \
    --kty RSA --size 2048 \
    --no-password --insecure \
    --force || return 1

  apply_tls_secret "$kubectl_bin" "$namespace" step-server-ca \
    "$workdir/server_ca.crt" "$workdir/server_ca.key" || return 1

  echo "$workdir/server_ca.crt:$workdir/server_ca.key"
}

# ensure_provisioner_password KUBECTL NAMESPACE WORKDIR NAME MOUNTED_PASSWORD_PATH
#
# Ensures a step-provisioner-NAME Secret's "password" field exists,
# generating (and applying) a random one if it's absent. Prints the path
# to use: newly generated material under WORKDIR, or MOUNTED_PASSWORD_PATH
# (the caller-supplied mount point of the optional Secret volume) if the
# secret already exists.
ensure_provisioner_password() {
  local kubectl_bin="$1"
  local namespace="$2"
  local workdir="$3"
  local name="$4"
  local mounted_password_path="$5"
  local secret_name="step-provisioner-$name"
  local password_file="$workdir/${name}_password"

  mkdir -p "$workdir" || return 1

  if secret_field "$kubectl_bin" "$namespace" "$secret_name" password "$workdir" >/dev/null; then
    echo "$mounted_password_path"
    return 0
  fi

  step crypto rand 32 >"$password_file" || return 1
  apply_opaque_secret "$kubectl_bin" "$namespace" "$secret_name" password "$password_file" || return 1

  echo "$password_file"
}

# main
#
# Entry point for the step-ca-init initContainer. Short-circuits if
# ca.json already exists (never regenerates/overwrites secrets on a
# re-run); otherwise resolves the operator-supplied step-root-ca material,
# ensures the step-server-ca and provisioner-password secrets exist
# (generating them on first run), and assembles ca.json: step ca init,
# the idrac/acme provisioners, and the authority policy/claims.
main() {
  local config_dir="${STEP_CONFIG_DIR:-/home/step}"
  local ca_config="$config_dir/config/ca.json"
  local root_ca_dir="${STEP_ROOT_CA_DIR:-/step/root-ca}"
  local root_crt="$root_ca_dir/tls.crt"
  local root_key="$root_ca_dir/tls.key"
  local root_password_file="$root_ca_dir/password"
  local namespace
  local ca_name="${STEP_CA_NAME:-SmallStep}"
  local dns_names="${STEP_DNS_NAMES:-}"
  local server_provisioner_name="${STEP_SERVER_PROVISIONER_NAME:-server}"
  local idrac_provisioner_name="${STEP_IDRAC_PROVISIONER_NAME:-idrac}"
  local acme_provisioner_name="${STEP_ACME_PROVISIONER_NAME:-acme}"
  local allow_dns="${STEP_POLICY_ALLOW_DNS:-}"
  local allow_ip="${STEP_POLICY_ALLOW_IP:-}"
  local default_duration="${STEP_DEFAULT_CERT_DURATION:-2160h}"
  local idrac_template_path
  local workdir
  local kubectl_bin
  local server_ca_paths server_ca_crt server_ca_key
  local server_password_path idrac_password_path

  if ca_already_initialized "$config_dir"; then
    echo "ca.json already exists at $ca_config - skipping initialization" >&2
    return 0
  fi

  # Checked before requiring NAMESPACE or fetching kubectl: an operator
  # restoring step-root-ca is the thing this failure is actually about,
  # and we want the message about that to win over any other missing
  # prerequisite.
  if [[ ! -f "$root_key" ]] || [[ ! -f "$root_password_file" ]]; then
    echo "step-root-ca secret is missing tls.key or password at $root_ca_dir -" \
      "restore step-root-ca from backup before retrying" >&2
    return 1
  fi

  namespace="${NAMESPACE:?NAMESPACE is required}"

  workdir="$(mktemp -d)" || return 1
  kubectl_bin="$(fetch_kubectl "$workdir")" || return 1

  server_ca_paths="$(ensure_server_ca "$kubectl_bin" "$namespace" "$workdir" \
    "$root_crt" "$root_key" "$root_password_file")" || return 1
  server_ca_crt="${server_ca_paths%%:*}"
  server_ca_key="${server_ca_paths##*:}"

  server_password_path="$(ensure_provisioner_password "$kubectl_bin" "$namespace" "$workdir" \
    "$server_provisioner_name" "/step/provisioner-$server_provisioner_name/password")" || return 1
  idrac_password_path="$(ensure_provisioner_password "$kubectl_bin" "$namespace" "$workdir" \
    "$idrac_provisioner_name" "/step/provisioner-$idrac_provisioner_name/password")" || return 1

  idrac_template_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/idrac-rsa.tpl"

  run_step_ca_init "$config_dir" "$ca_name" "$dns_names" "$server_provisioner_name" \
    "$server_password_path" \
    "$root_crt" "$root_key" "$root_password_file" \
    "$server_ca_crt" "$server_ca_key" || return 1

  add_idrac_provisioner "$ca_config" "$idrac_provisioner_name" \
    "$idrac_password_path" "$idrac_template_path" || return 1
  add_acme_provisioner "$ca_config" "$acme_provisioner_name" || return 1
  apply_authority_policy "$ca_config" "$allow_dns" "$allow_ip" "$default_duration" || return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
