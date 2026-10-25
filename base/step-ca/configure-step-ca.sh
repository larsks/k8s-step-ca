#!/bin/bash
#
# Post-init configuration for step-ca, applied over the remote
# administration API once the CA is up. This is where we add
# provisioners/policy that `step ca init` has no flags for, rather than
# hand-editing ca.json.
#
# Safe to re-run: skips the provisioner add if it already exists, and
# relies on `step ca policy ... allow` being a set-union operation.

set -e

: "${STEP_CA_URL:?STEP_CA_URL is required}"
: "${STEP_ROOT_CERTIFICATE:?STEP_ROOT_CERTIFICATE is required}"
: "${STEP_PASSWORD_FILE:?STEP_PASSWORD_FILE is required}"

admin_subject="${STEP_ADMIN_SUBJECT:-step}"
admin_provisioner="${STEP_PROVISIONER_NAME:-admin}"
idrac_provisioner="${STEP_IDRAC_PROVISIONER_NAME:-idrac}"
server_jwt_provisioner="${STEP_SERVER_JWT_PROVISIONER_NAME:-server-jwt}"
server_x5c_provisioner="${STEP_SERVER_X5C_PROVISIONER_NAME:-server-x5c}"

conn_flags=(--ca-url="$STEP_CA_URL" --root="$STEP_ROOT_CERTIFICATE")
admin_auth=(
  --admin-subject="$admin_subject"
  --admin-provisioner="$admin_provisioner"
  --admin-password-file="$STEP_PASSWORD_FILE"
)

ensure_jwk_provisioner() {
  local name=$1
  if step ca provisioner list "${conn_flags[@]}" | grep -q "\"name\": *\"${name}\""; then
    echo "provisioner '${name}' already exists, skipping" >&2
  else
    echo "adding provisioner '${name}'" >&2
    step ca provisioner add "$name" \
      --type=JWK \
      --create \
      --password-file="$STEP_PASSWORD_FILE" \
      "${admin_auth[@]}" "${conn_flags[@]}"
  fi
}

ensure_x5c_provisioner() {
  local name=$1
  local roots=$2
  if step ca provisioner list "${conn_flags[@]}" | grep -q "\"name\": *\"${name}\""; then
    echo "provisioner '${name}' already exists, skipping" >&2
  else
    echo "adding provisioner '${name}'" >&2
    step ca provisioner add "$name" \
      --type=X5C \
      --x5c-roots="$roots" \
      "${admin_auth[@]}" "${conn_flags[@]}"
  fi
}

remove_provisioner_if_present() {
  local name=$1
  if step ca provisioner list "${conn_flags[@]}" | grep -q "\"name\": *\"${name}\""; then
    echo "removing superseded provisioner '${name}'" >&2
    step ca provisioner remove "$name" "${admin_auth[@]}" "${conn_flags[@]}"
  fi
}

echo "waiting for CA at $STEP_CA_URL to become healthy" >&2
for _ in $(seq 1 60); do
  if step ca health "${conn_flags[@]}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
step ca health "${conn_flags[@]}"

ensure_jwk_provisioner "$idrac_provisioner"

echo "applying RSA-only x509 template to provisioner '${idrac_provisioner}'" >&2
step ca provisioner update "$idrac_provisioner" \
  --x509-template=/scripts/idrac-rsa.tpl \
  "${admin_auth[@]}" "${conn_flags[@]}"

# "server-jwt"/"server-x5c" are for non-ACME devices/services that don't
# need the iDRAC RSA-only restriction - no x509 template is applied, so
# key type is unconstrained.
#
# server-jwt: JWK-authenticated, used to bootstrap a server's initial
# certificate.
# server-x5c: X5C-authenticated, used for subsequent reissuance (e.g. key
# rotation, or a new duration) once a server already holds a cert issued
# by this CA, authenticating with that cert instead of the shared JWK
# password.
#
# "server-jwt" was previously named "server"; remove the old name so it
# isn't left behind alongside the new one.
remove_provisioner_if_present "server"
ensure_jwk_provisioner "$server_jwt_provisioner"
ensure_x5c_provisioner "$server_x5c_provisioner" "$STEP_ROOT_CERTIFICATE"

# The authority-level x509 allow list is deny-by-default for any SAN type
# it touches: once *any* dns entry is added, only listed names are
# issuable. The admin subject's own x5c bootstrap certificate needs a DNS
# SAN matching its subject, so it must be allowed explicitly or every
# future remote-admin call locks itself out.
echo "allowing admin subject '${admin_subject}' as a dns name, so authority policy doesn't lock out remote administration" >&2
step ca policy authority x509 allow dns "$admin_subject" "${admin_auth[@]}" "${conn_flags[@]}"

if [[ -n "$STEP_POLICY_ALLOW_DNS" ]]; then
  echo "allowing dns SAN pattern '${STEP_POLICY_ALLOW_DNS}' at authority scope" >&2
  step ca policy authority x509 allow dns "$STEP_POLICY_ALLOW_DNS" "${admin_auth[@]}" "${conn_flags[@]}"
fi

if [[ -n "$STEP_POLICY_ALLOW_IP" ]]; then
  echo "allowing ip SAN range '${STEP_POLICY_ALLOW_IP}' at authority scope" >&2
  step ca policy authority x509 allow ip "$STEP_POLICY_ALLOW_IP" "${admin_auth[@]}" "${conn_flags[@]}"
fi

step ca policy authority view "${admin_auth[@]}" "${conn_flags[@]}"
