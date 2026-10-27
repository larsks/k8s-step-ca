#!/bin/bash

# set_default_cert_duration CA_CONFIG DEFAULT_DURATION
#
# Sets the default TLS certificate duration in the ca.json at CA_CONFIG.
# Keys are assigned, not appended, so re-running produces the same result.
#
# SAN restrictions are deliberately NOT handled here (nor anywhere at
# authority.policy): self-hosted step-ca only supports policy at the
# authority level, applying to every provisioner, and the policy engine
# has no wildcard that matches a bare single-label DNS name. BMCs like
# Lenovo XCC unconditionally embed their own bare hostname as a SAN in
# any CSR they generate, which a policy-based allow list can never admit
# - and since "all names in a request must be allowed or the request is
# rejected", one such device poisons every signing request, including
# ones that would otherwise be fine. SAN filtering is done per-provisioner
# instead, via the x509 template attached by attach_x509_template (see
# x509-filter.tpl); key-type restrictions (e.g. iDRAC's RSA-only
# requirement) are injected the same way, as template data.
set_default_cert_duration() {
  local ca_config="$1"
  local default_duration="$2"
  local tmp

  tmp="$(mktemp "${ca_config}.XXXXXX")" || return 1
  if jq \
    --arg duration "$default_duration" \
    '.authority.claims.defaultTLSCertDuration = $duration' \
    "$ca_config" >"$tmp"; then
    mv "$tmp" "$ca_config"
  else
    rm -f "$tmp"
    return 1
  fi
}

# dns_allow_suffixes ALLOW_DNS
#
# Converts a comma-separated list of DNS allow patterns (e.g.
# "*.massopen.cloud,*.net.massopen.cloud") into a JSON array of suffixes
# for the shared x509 templates' SAN filter, which keeps a DNS SAN when it
# has one of these as a (Sprig `hasSuffix`) suffix. A leading "*" is
# stripped from each pattern; entries without a leading "*" are used
# as-is, so e.g. "ipv6-literal.net" would also match "evilipv6-literal.net"
# - prefer "*."-prefixed patterns unless that looseness is intentional.
dns_allow_suffixes() {
  local allow_dns="$1"
  local pattern
  local json="[]"

  IFS=',' read -ra patterns <<<"$allow_dns"
  for pattern in "${patterns[@]}"; do
    [[ -n "$pattern" ]] || continue
    pattern="${pattern#\*}"
    json="$(jq --arg s "$pattern" '. + [$s]' <<<"$json")" || return 1
  done
  echo "$json"
}

# ip_allow_prefixes ALLOW_IP
#
# Converts a comma-separated list of IP allow entries into a JSON array of
# string prefixes for the shared x509 templates' SAN filter, which keeps
# an IP SAN when it has one of these as a (Sprig `hasPrefix`) prefix.
# Octet-aligned IPv4 CIDRs (/8, /16, /24, /32) are converted to their
# dotted-decimal prefix (e.g. "10.0.0.0/8" -> "10."); an entry with no "/"
# is used verbatim as a literal prefix (e.g. "fe80:" for IPv6 link-local
# addresses). Templates have no general netmask arithmetic available, so
# any other CIDR form is an error rather than a silently-wrong prefix.
ip_allow_prefixes() {
  local allow_ip="$1"
  local entry prefix mask a b c d
  local json="[]"

  IFS=',' read -ra entries <<<"$allow_ip"
  for entry in "${entries[@]}"; do
    [[ -n "$entry" ]] || continue
    if [[ "$entry" != */* ]]; then
      prefix="$entry"
    else
      mask="${entry#*/}"
      IFS='.' read -r a b c d <<<"${entry%/*}"
      case "$mask" in
      8) prefix="$a." ;;
      16) prefix="$a.$b." ;;
      24) prefix="$a.$b.$c." ;;
      32) prefix="$a.$b.$c.$d" ;;
      *)
        echo "ip_allow_prefixes: unsupported CIDR mask /$mask in '$entry' -" \
          "only /8, /16, /24 and /32 IPv4 CIDRs are auto-converted;" \
          "pass a bare prefix (e.g. 'fe80:') for other ranges" >&2
        return 1
        ;;
      esac
    fi
    json="$(jq --arg s "$prefix" '. + [$s]' <<<"$json")" || return 1
  done
  echo "$json"
}

# csv_to_json_array CSV
#
# Converts a comma-separated list into a JSON array of strings, with no
# other transformation. Used for values the shared x509 template compares
# with plain equality, e.g. AllowedKeyTypes.
csv_to_json_array() {
  local csv="$1"
  local item
  local json="[]"

  IFS=',' read -ra items <<<"$csv"
  for item in "${items[@]}"; do
    [[ -n "$item" ]] || continue
    json="$(jq --arg s "$item" '. + [$s]' <<<"$json")" || return 1
  done
  echo "$json"
}

# build_x509_template_data ALLOW_DNS ALLOW_IP ALLOWED_KEY_TYPES OUT_FILE
#
# Writes {"AllowDNSSuffixes": [...], "AllowIPPrefixes": [...],
# "AllowedKeyTypes": [...]} to OUT_FILE, for use as the
# --x509-template-data of the shared x509-filter.tpl template (see
# attach_x509_template). ALLOWED_KEY_TYPES is a comma-separated list of
# "RSA", "ECDSA" and/or "Ed25519"; an empty list means any key type is
# allowed - unlike the SAN lists, where an empty list means no SAN of that
# type is allowed, since an unset key-type restriction should mean "don't
# restrict" rather than "reject everything".
build_x509_template_data() {
  local allow_dns="$1"
  local allow_ip="$2"
  local allowed_key_types="$3"
  local out_file="$4"
  local dns_json ip_json key_types_json

  dns_json="$(dns_allow_suffixes "$allow_dns")" || return 1
  ip_json="$(ip_allow_prefixes "$allow_ip")" || return 1
  key_types_json="$(csv_to_json_array "$allowed_key_types")" || return 1

  jq -n --argjson dns "$dns_json" --argjson ip "$ip_json" --argjson keyTypes "$key_types_json" \
    '{AllowDNSSuffixes: $dns, AllowIPPrefixes: $ip, AllowedKeyTypes: $keyTypes}' >"$out_file"
}

# attach_x509_template CA_CONFIG NAME TEMPLATE_PATH TEMPLATE_DATA_PATH
#
# Attaches the x509 certificate template at TEMPLATE_PATH, and the
# template data at TEMPLATE_DATA_PATH (see build_sans_template_data), to
# the existing provisioner NAME in the ca.json at CA_CONFIG.
attach_x509_template() {
  local ca_config="$1"
  local name="$2"
  local template_path="$3"
  local template_data_path="$4"
  local step_path

  step_path="$(dirname "$(dirname "$ca_config")")"

  STEPPATH="$step_path" step ca provisioner update "$name" \
    --x509-template="$template_path" \
    --x509-template-data="$template_data_path" \
    --ca-config="$ca_config" || return 1
}

# run_step_ca_init CONFIG_DIR CA_NAME DNS_NAMES PROVISIONER_NAME \
#   PROVISIONER_PASSWORD_FILE ROOT_CRT ROOT_KEY ROOT_PASSWORD_FILE \
#   SERVER_CA_CRT SERVER_CA_KEY SERVER_CA_PASSWORD_FILE
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
# SERVER_CA_KEY is encrypted with the password in SERVER_CA_PASSWORD_FILE.
#
# Any config/, certs/, secrets/ or templates/ left under CONFIG_DIR by an
# earlier, interrupted run are removed first: `step ca init` refuses to
# run non-interactively over an existing ca.json, and a partial run's
# output is never trusted (see ca_already_initialized).
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
  local server_ca_password_file="${11}"
  local -a dns_args=()
  local -a dns_list=()
  local name

  rm -rf "$config_dir/config" "$config_dir/certs" \
    "$config_dir/secrets" "$config_dir/templates" || return 1

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
  chmod 0600 "$config_dir/secrets/intermediate_ca_key" || return 1

  # The step-ca server process (the smallstep/step-ca image's default
  # command) is started as `step-ca --password-file
  # /home/step/secrets/password /home/step/config/ca.json`, and uses that
  # password to decrypt secrets/intermediate_ca_key - so this must be the
  # server CA's key password, not the provisioner's.
  cp "$server_ca_password_file" "$config_dir/secrets/password" || return 1
  chmod 0600 "$config_dir/secrets/password" || return 1
}

# add_idrac_provisioner CA_CONFIG NAME PASSWORD_FILE TEMPLATE_PATH
#   TEMPLATE_DATA_PATH
#
# Adds a JWK provisioner named NAME to the ca.json at CA_CONFIG, then
# attaches the x509 certificate template at TEMPLATE_PATH (and the
# template data at TEMPLATE_DATA_PATH) to it - see attach_x509_template.
# TEMPLATE_DATA_PATH is expected to set AllowedKeyTypes to ["RSA"], since
# iDRAC devices don't support EC/Ed25519 certificates.
add_idrac_provisioner() {
  local ca_config="$1"
  local name="$2"
  local password_file="$3"
  local template_path="$4"
  local template_data_path="$5"
  local step_path

  step_path="$(dirname "$(dirname "$ca_config")")"

  STEPPATH="$step_path" step ca provisioner add "$name" \
    --type=JWK --create --password-file="$password_file" \
    --ca-config="$ca_config" || return 1
  attach_x509_template "$ca_config" "$name" "$template_path" "$template_data_path" || return 1
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

# init_marker CONFIG_DIR
#
# Prints the path of the completion marker that main() writes as its very
# last step, once every part of initialization has succeeded.
init_marker() {
  local config_dir="$1"

  echo "$config_dir/config/.step-ca-initialized"
}

# ca_already_initialized CONFIG_DIR
#
# Returns 0 if a previous run of main() against CONFIG_DIR completed
# successfully (its completion marker exists), 1 otherwise. Deliberately
# not keyed off ca.json: `step ca init` writes ca.json early, so a run
# that fails (or is killed) after that point leaves a ca.json behind that
# is missing provisioners and/or policy. Without the marker, the next pod
# start redoes initialization from scratch instead of serving that
# half-built CA.
ca_already_initialized() {
  local config_dir="$1"

  [[ -f "$(init_marker "$config_dir")" ]]
}

# root_is_rsa ROOT_CRT
#
# Returns 0 if the certificate at ROOT_CRT has an RSA public key, 1
# otherwise (including if it can't be parsed). Dell iDRAC 8 requires every
# certificate in its trust chain to be RSA.
root_is_rsa() {
  local root_crt="$1"
  local inspected

  inspected="$(step certificate inspect --format json "$root_crt")" || return 1
  jq -e '.subject_key_info.key_algorithm.name == "RSA"' <<<"$inspected" >/dev/null
}

# fetch_kubectl WORKDIR
#
# Downloads the current stable `kubectl` release for this machine's
# architecture into WORKDIR, verifies it against the sha256 checksum
# published alongside it, and prints its path. Never installs over a
# system binary: callers get back a path to use directly, so this script
# never depends on (or risks colliding with) a `kubectl` already on PATH.
#
# The checksum is fetched from the same origin as the binary, so it
# guards against truncated/corrupted downloads and error pages rather
# than against a compromised dl.k8s.io.
fetch_kubectl() {
  local workdir="$1"
  local kubectl_path="$workdir/kubectl"
  local kubectl_version arch url expected actual

  case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *)
    echo "fetch_kubectl: unsupported architecture $(uname -m)" >&2
    return 1
    ;;
  esac

  mkdir -p "$workdir" || return 1
  kubectl_version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)" || return 1
  if [[ ! "$kubectl_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "fetch_kubectl: unexpected kubectl version string '$kubectl_version'" >&2
    return 1
  fi

  url="https://dl.k8s.io/release/${kubectl_version}/bin/linux/${arch}/kubectl"
  curl -fsSLo "$kubectl_path" "$url" || return 1
  expected="$(curl -fsSL "$url.sha256")" || {
    rm -f "$kubectl_path"
    return 1
  }
  expected="${expected%%[[:space:]]*}"
  actual="$(sha256sum "$kubectl_path")" || {
    rm -f "$kubectl_path"
    return 1
  }
  actual="${actual%% *}"

  if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    echo "fetch_kubectl: sha256 mismatch for $url (expected '$expected', got '$actual')" >&2
    rm -f "$kubectl_path"
    return 1
  fi

  chmod +x "$kubectl_path" || return 1
  echo "$kubectl_path"
}

# secret_field KUBECTL NAMESPACE SECRET FIELD
#
# Prints the decoded value of FIELD from SECRET in NAMESPACE, using
# KUBECTL (a path to a kubectl binary). Returns:
#
#   0 - FIELD is present and non-empty; its decoded value is printed
#   1 - SECRET doesn't exist, or exists without a non-empty FIELD
#   2 - the lookup itself failed (API/auth error) or FIELD isn't valid
#       base64; a message is printed to stderr
#
# The template prints nothing (rather than `<no value>`, as a bare
# `{{index .data "FIELD"}}` does) when .data or FIELD is missing, and
# --ignore-not-found makes a missing secret print nothing and exit 0, so
# every "absent" case is an empty result and any non-zero kubectl exit is
# a genuine error rather than "not found".
secret_field() {
  local kubectl_bin="$1"
  local namespace="$2"
  local secret="$3"
  local field="$4"
  local encoded

  encoded="$("$kubectl_bin" -n "$namespace" get secret "$secret" --ignore-not-found \
    -o go-template="{{with .data}}{{with index . \"$field\"}}{{.}}{{end}}{{end}}")" || {
    echo "failed to look up secret $secret in namespace $namespace" >&2
    return 2
  }
  [[ -n "$encoded" ]] || return 1

  base64 -d <<<"$encoded" || {
    echo "field $field of secret $secret is not valid base64" >&2
    return 2
  }
}

# create_tls_secret KUBECTL NAMESPACE NAME CRT KEY PASSWORD_FILE
#
# Creates a kubernetes.io/tls Secret named NAME containing CRT/KEY as
# tls.crt/tls.key, and the content of PASSWORD_FILE (the password KEY is
# encrypted with) as password. Uses `kubectl create`, not `apply`: this is
# the one-shot "generate it because it didn't exist a moment ago" path,
# and only `create`'s atomicity lets a caller detect - rather than
# silently overwrite - a Secret that a concurrently running init
# generated first. Returns:
#
#   0 - created
#   1 - the create failed for a reason other than already existing; a
#       message is printed to stderr
#   2 - NAME already exists (lost a race with another concurrently
#       running init); nothing was changed
create_tls_secret() {
  local kubectl_bin="$1"
  local namespace="$2"
  local name="$3"
  local crt="$4"
  local key="$5"
  local password_file="$6"
  local err rc

  err="$(
    cat <<EOF | "$kubectl_bin" create -f - 2>&1 1>/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: $name
  namespace: $namespace
type: kubernetes.io/tls
data:
  tls.crt: $(base64 -w0 <"$crt")
  tls.key: $(base64 -w0 <"$key")
  password: $(base64 -w0 <"$password_file")
EOF
  )"
  rc=$?

  if ((rc == 0)); then
    return 0
  elif [[ "$err" == *AlreadyExists* ]]; then
    return 2
  else
    echo "$err" >&2
    return 1
  fi
}

# create_opaque_secret KUBECTL NAMESPACE NAME FIELD FILE
#
# Creates an Opaque Secret named NAME containing a single FIELD key whose
# value is the content of FILE. Uses `kubectl create`, not `apply`, for
# the same race-detection reason as create_tls_secret. Returns:
#
#   0 - created
#   1 - the create failed for a reason other than already existing; a
#       message is printed to stderr
#   2 - NAME already exists (lost a race with another concurrently
#       running init); nothing was changed
create_opaque_secret() {
  local kubectl_bin="$1"
  local namespace="$2"
  local name="$3"
  local field="$4"
  local file="$5"
  local err rc

  err="$(
    cat <<EOF | "$kubectl_bin" create -f - 2>&1 1>/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: $name
  namespace: $namespace
type: Opaque
data:
  $field: $(base64 -w0 <"$file")
EOF
  )"
  rc=$?

  if ((rc == 0)); then
    return 0
  elif [[ "$err" == *AlreadyExists* ]]; then
    return 2
  else
    echo "$err" >&2
    return 1
  fi
}

# root_ca_fingerprint ROOT_CRT
#
# Prints the sha256 fingerprint of the certificate at ROOT_CRT, in the
# same hex form `step ca bootstrap --fingerprint` expects.
root_ca_fingerprint() {
  local root_crt="$1"

  step certificate fingerprint "$root_crt"
}

# create_fingerprint_configmap KUBECTL NAMESPACE NAME FINGERPRINT
#
# Creates a ConfigMap named NAME with a single "fingerprint" key set to
# FINGERPRINT, for clients that bootstrap against this CA (e.g. `step ca
# bootstrap --fingerprint`/--team-url) without cluster API access of
# their own - see fetch_kubectl's docstring for why this script can't
# assume kubectl is already on PATH, and the webserver/ingress fronting
# this ConfigMap is out of scope here.
#
# Uses `kubectl create`, not `apply`, for the same race-detection reason
# as create_tls_secret/create_opaque_secret. Unlike those, a losing race
# is treated as success rather than adopted: the fingerprint is wholly
# determined by ROOT_CRT, so whatever a concurrently running init already
# wrote is the same value this one would have written. Returns:
#
#   0 - created, or already existed (necessarily with the same value)
#   1 - the create failed for a reason other than already existing; a
#       message is printed to stderr
create_fingerprint_configmap() {
  local kubectl_bin="$1"
  local namespace="$2"
  local name="$3"
  local fingerprint="$4"
  local err rc

  err="$(
    cat <<EOF | "$kubectl_bin" create -f - 2>&1 1>/dev/null
apiVersion: v1
kind: ConfigMap
metadata:
  name: $name
  namespace: $namespace
data:
  fingerprint: "$fingerprint"
EOF
  )"
  rc=$?

  if ((rc == 0)); then
    return 0
  elif [[ "$err" == *AlreadyExists* ]]; then
    return 0
  else
    echo "$err" >&2
    return 1
  fi
}

# ensure_server_ca KUBECTL NAMESPACE WORKDIR ROOT_CRT ROOT_KEY ROOT_PASSWORD_FILE
#   SERVER_CA_NAME
#
# Ensures a complete step-server-ca Secret (tls.crt, tls.key, password)
# exists. If tls.crt or tls.key is missing, generates a new RSA
# intermediate signed by ROOT_CRT/ROOT_KEY, its key encrypted with a
# freshly generated random password, and creates the Secret. If tls.crt
# and tls.key are present but password is not, fails rather than
# overwriting what may be an operator-supplied intermediate.
#
# The create is atomic: if another concurrently running init already
# created step-server-ca between this function's initial read and its
# own create call, that create fails with AlreadyExists rather than
# silently overwriting the winner's Secret, and this function adopts the
# winner's material instead of its own, now-orphaned, generated one. This
# is what keeps two concurrent inits (e.g. an old pod's initContainer
# still finishing as its replacement starts) from leaving the Secret and
# the locally assembled ca.json encrypted with two different passwords.
#
# Either way, writes the resolved certificate, key and key password to
# WORKDIR and prints their paths, one per line, in that order - always
# WORKDIR paths, never a volume mount, so the result reflects the Secret
# as it is in the API right now.
ensure_server_ca() {
  local kubectl_bin="$1"
  local namespace="$2"
  local workdir="$3"
  local root_crt="$4"
  local root_key="$5"
  local root_password_file="$6"
  local server_ca_name="$7"
  local crt="$workdir/server_ca.crt"
  local key="$workdir/server_ca.key"
  local password_file="$workdir/server_ca_password"
  local crt_rc key_rc password_rc

  mkdir -p "$workdir" || return 1

  secret_field "$kubectl_bin" "$namespace" step-server-ca tls.crt >"$crt"
  crt_rc=$?
  secret_field "$kubectl_bin" "$namespace" step-server-ca tls.key >"$key"
  key_rc=$?
  secret_field "$kubectl_bin" "$namespace" step-server-ca password >"$password_file"
  password_rc=$?

  if ((crt_rc > 1 || key_rc > 1 || password_rc > 1)); then
    return 1
  fi

  if ((crt_rc == 0 && key_rc == 0)); then
    if ((password_rc != 0)); then
      echo "step-server-ca has tls.crt and tls.key but no password -" \
        "add the key's password to the secret, or delete the secret to regenerate it" >&2
      return 1
    fi
    printf '%s\n' "$crt" "$key" "$password_file"
    return 0
  fi

  step crypto rand 32 >"$password_file" || return 1
  step certificate create "$server_ca_name" "$crt" "$key" \
    --profile intermediate-ca \
    --ca "$root_crt" --ca-key "$root_key" --ca-password-file "$root_password_file" \
    --kty RSA --size 2048 \
    --password-file "$password_file" \
    --force >&2 || return 1

  create_tls_secret "$kubectl_bin" "$namespace" step-server-ca "$crt" "$key" "$password_file"
  case $? in
  0) ;;
  2)
    # Something now has the name that didn't (or wasn't complete) at the
    # read above. Re-check: a concurrently running init that just created
    # a complete Secret is the race this is meant to catch - adopt its
    # material instead of our own, now-orphaned, generated one. A Secret
    # that's still incomplete isn't a race winner, it's a stale/broken
    # object our own create can't safely absorb (create has no "fill in
    # the missing fields" semantics, unlike apply) - fail instead of
    # looping on it, same as the complete-but-no-password case above.
    secret_field "$kubectl_bin" "$namespace" step-server-ca tls.crt >"$crt"
    crt_rc=$?
    secret_field "$kubectl_bin" "$namespace" step-server-ca tls.key >"$key"
    key_rc=$?
    secret_field "$kubectl_bin" "$namespace" step-server-ca password >"$password_file"
    password_rc=$?
    if ((crt_rc > 1 || key_rc > 1 || password_rc > 1)); then
      return 1
    elif ((crt_rc != 0 || key_rc != 0 || password_rc != 0)); then
      echo "step-server-ca already exists but is missing tls.crt, tls.key or password -" \
        "complete it, or delete the secret to regenerate it" >&2
      return 1
    fi
    ;;
  *) return 1 ;;
  esac

  printf '%s\n' "$crt" "$key" "$password_file"
}

# ensure_provisioner_password KUBECTL NAMESPACE WORKDIR NAME
#
# Ensures a step-provisioner-NAME Secret's "password" field exists,
# generating a random one and creating the Secret if it's absent. Either
# way, writes the resolved password to WORKDIR and prints that path -
# never a volume mount, so the result reflects the Secret as it is in
# the API right now.
#
# The create is atomic: if another concurrently running init already
# created step-provisioner-NAME since the read above, that create fails
# with AlreadyExists rather than silently overwriting the winner's
# Secret, and this function adopts the winner's password instead of its
# own, now-orphaned, generated one - see create_opaque_secret.
ensure_provisioner_password() {
  local kubectl_bin="$1"
  local namespace="$2"
  local workdir="$3"
  local name="$4"
  local secret_name="step-provisioner-$name"
  local password_file="$workdir/${name}_password"
  local rc

  mkdir -p "$workdir" || return 1

  secret_field "$kubectl_bin" "$namespace" "$secret_name" password >"$password_file"
  rc=$?
  if ((rc == 0)); then
    echo "$password_file"
    return 0
  elif ((rc > 1)); then
    return 1
  fi

  step crypto rand 32 >"$password_file" || return 1
  create_opaque_secret "$kubectl_bin" "$namespace" "$secret_name" password "$password_file"
  case $? in
  0) ;;
  2)
    # Something now has this name that didn't at the read above. A
    # concurrently running init that just created it with a password is
    # the race this is meant to catch - adopt its password instead of
    # our own, now-orphaned, generated one. A Secret that still has no
    # password isn't a race winner, it's a stale/broken object our own
    # create can't safely absorb (create has no "fill in the missing
    # field" semantics, unlike apply) - fail instead of looping on it.
    secret_field "$kubectl_bin" "$namespace" "$secret_name" password >"$password_file"
    rc=$?
    if ((rc > 1)); then
      return 1
    elif ((rc != 0)); then
      echo "$secret_name already exists but has no password field -" \
        "add one, or delete the secret to regenerate it" >&2
      return 1
    fi
    ;;
  *) return 1 ;;
  esac

  echo "$password_file"
}

# main
#
# Entry point for the step-ca-init initContainer. Every run - whether or
# not step-ca was already initialized - (re-)publishes the step-root-ca
# fingerprint to a ConfigMap (idempotently: create_fingerprint_configmap
# treats "already exists" as success), since that's cheap, has no
# generated secrets to protect from being overwritten, and should recover
# on its own if the ConfigMap is ever deleted. It only needs tls.crt,
# which - unlike tls.key/password - is expected to remain in step-root-ca
# for the life of the CA (see step-ca-init.md's documented post-init
# secret swap), so this works whether or not step-ca was already
# initialized.
#
# Short-circuits the rest of initialization if a previous run completed
# (never regenerates/overwrites secrets on a re-run); otherwise resolves
# the remaining operator-supplied step-root-ca material, ensures the
# step-server-ca and provisioner-password secrets exist (generating them
# on first run), and assembles ca.json: step ca init, the idrac/acme
# provisioners, the server/idrac SAN-filtering x509 templates, and the
# default cert duration claim. Only once all of that has succeeded does
# it write the completion marker; a run that fails part-way is retried in
# full on the next pod start.
main() {
  local config_dir="${STEP_CONFIG_DIR:-/home/step}"
  local ca_config="$config_dir/config/ca.json"
  local root_ca_dir="${STEP_ROOT_CA_DIR:-/step/root-ca}"
  local root_crt="$root_ca_dir/tls.crt"
  local root_key="$root_ca_dir/tls.key"
  local root_password_file="$root_ca_dir/password"
  local namespace
  local ca_name="${STEP_CA_NAME:-SmallStep Root CA}"
  local server_ca_name="${STEP_SERVER_CA_NAME:-SmallStep Server CA}"
  local dns_names="${STEP_DNS_NAMES:-}"
  local server_provisioner_name="${STEP_SERVER_PROVISIONER_NAME:-server}"
  local idrac_provisioner_name="${STEP_IDRAC_PROVISIONER_NAME:-idrac}"
  local acme_provisioner_name="${STEP_ACME_PROVISIONER_NAME:-acme}"
  local allow_dns="${STEP_POLICY_ALLOW_DNS:-}"
  local allow_ip="${STEP_POLICY_ALLOW_IP:-}"
  local idrac_allowed_key_types="${STEP_IDRAC_ALLOWED_KEY_TYPES:-RSA}"
  local server_allowed_key_types="${STEP_SERVER_ALLOWED_KEY_TYPES:-}"
  local default_duration="${STEP_DEFAULT_CERT_DURATION:-2160h}"
  local fingerprint_configmap_name="${STEP_ROOT_CA_FINGERPRINT_CONFIGMAP:-step-root-ca-fingerprint}"
  local fingerprint
  local marker
  local script_dir template_path idrac_template_data_path server_template_data_path
  local workdir
  local kubectl_bin
  local server_ca_paths server_ca_crt server_ca_key server_ca_password_file
  local server_password_path idrac_password_path

  marker="$(init_marker "$config_dir")"

  # tls.crt must always be present (see the main() docstring); checked
  # before requiring NAMESPACE or fetching kubectl so a missing root
  # certificate is reported on its own, rather than as a confusing
  # NAMESPACE-is-unset failure.
  if [[ ! -f "$root_crt" ]]; then
    echo "step-root-ca secret is missing tls.crt at $root_ca_dir -" \
      "restore step-root-ca from backup before retrying" >&2
    return 1
  fi

  namespace="${NAMESPACE:?NAMESPACE is required}"

  workdir="$(mktemp -d)" || return 1
  # Expanded now rather than when the trap fires: workdir is local to
  # main, and out of scope by the time the script exits.
  # shellcheck disable=SC2064
  trap "rm -rf $(printf '%q' "$workdir")" EXIT

  kubectl_bin="$(fetch_kubectl "$workdir")" || return 1

  fingerprint="$(root_ca_fingerprint "$root_crt")" || return 1
  create_fingerprint_configmap "$kubectl_bin" "$namespace" \
    "$fingerprint_configmap_name" "$fingerprint" || return 1

  if ca_already_initialized "$config_dir"; then
    echo "step-ca already initialized ($marker exists) - skipping initialization" >&2
    return 0
  fi

  if [[ -f "$ca_config" ]]; then
    echo "$ca_config exists but $marker does not - a previous initialization" \
      "did not complete; re-initializing from scratch" >&2
  fi

  # tls.key/password may legitimately be absent at this point if step-ca
  # was already initialized (see above) - but it wasn't, so the operator
  # hasn't finished provisioning step-root-ca yet.
  if [[ ! -f "$root_key" ]] || [[ ! -f "$root_password_file" ]]; then
    echo "step-root-ca secret is missing tls.key or password at $root_ca_dir -" \
      "restore step-root-ca from backup before retrying" >&2
    return 1
  fi

  if ! root_is_rsa "$root_crt"; then
    echo "step-root-ca tls.crt at $root_crt is not an RSA certificate -" \
      "Dell iDRAC 8 requires an all-RSA trust chain, so step-root-ca must be RSA" >&2
    return 1
  fi

  server_ca_paths="$(ensure_server_ca "$kubectl_bin" "$namespace" "$workdir" \
    "$root_crt" "$root_key" "$root_password_file" "$server_ca_name")" || return 1
  {
    read -r server_ca_crt
    read -r server_ca_key
    read -r server_ca_password_file
  } <<<"$server_ca_paths"

  server_password_path="$(ensure_provisioner_password "$kubectl_bin" "$namespace" "$workdir" \
    "$server_provisioner_name")" || return 1
  idrac_password_path="$(ensure_provisioner_password "$kubectl_bin" "$namespace" "$workdir" \
    "$idrac_provisioner_name")" || return 1

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  template_path="$script_dir/x509-filter.tpl"
  idrac_template_data_path="$workdir/idrac-template-data.json"
  server_template_data_path="$workdir/server-template-data.json"
  build_x509_template_data "$allow_dns" "$allow_ip" "$idrac_allowed_key_types" \
    "$idrac_template_data_path" || return 1
  build_x509_template_data "$allow_dns" "$allow_ip" "$server_allowed_key_types" \
    "$server_template_data_path" || return 1

  run_step_ca_init "$config_dir" "$ca_name" "$dns_names" "$server_provisioner_name" \
    "$server_password_path" \
    "$root_crt" "$root_key" "$root_password_file" \
    "$server_ca_crt" "$server_ca_key" "$server_ca_password_file" || return 1

  attach_x509_template "$ca_config" "$server_provisioner_name" \
    "$template_path" "$server_template_data_path" || return 1
  add_idrac_provisioner "$ca_config" "$idrac_provisioner_name" \
    "$idrac_password_path" "$template_path" "$idrac_template_data_path" || return 1
  add_acme_provisioner "$ca_config" "$acme_provisioner_name" || return 1
  set_default_cert_duration "$ca_config" "$default_duration" || return 1

  touch "$marker" || return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
