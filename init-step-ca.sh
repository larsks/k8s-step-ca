#!/bin/bash

if [[ -z "$STEP_PASSWORD_FILE" ]]; then
  echo "ERROR: cannot continue without STEP_PASSWORD_FILE" >&2
  exit 1
fi

step_ca_init_args=(
  --deployment-type=standalone
  --name="${STEP_CA_NAME:-SmallStep}"
  --address :9000
  --provisioner="${STEP_PROVISIONER_NAME:-admin}"
  --password-file="$STEP_PASSWORD_FILE"
  --dns=localhost
)

if [[ $STEP_ENABLE_ACME = 1 ]]; then
  step_ca_init_args+=(
    --acme
  )
fi

if [[ $STEP_REMOTE_MANAGEMENT = 1 ]]; then
  step_ca_init_args+=(
    --remote-management
    --admin-subject="${STEP_ADMIN_SUBJECT:-step}"
  )
fi

if [[ -n "$STEP_DNS_NAMES" ]]; then
  mapfile -d, -t dns_names <<<"$STEP_DNS_NAMES"
  for name in "${dns_names[@]}"; do
    step_ca_init_args+=(
      --dns="$name"
    )
  done
fi

if [[ -n "$STEP_CA_CERTIFICATE_FILE" ]]; then
  if [[ -z "$STEP_CA_KEY_FILE" ]]; then
    echo "ERROR: cannot use STEP_CA_CERTIFICATE_FILE without STEP_CA_KEY_FILE" >&2
    exit 1
  fi

  step_ca_init_args+=(
    --root="$STEP_CA_CERTIFICATE_FILE"
    --key="$STEP_CA_KEY_FILE"
  )

  if [[ -n "$STEP_CA_KEY_PASSWORD_FILE" ]]; then
    step_ca_init_args+=(
      --key-password-file="$STEP_CA_KEY_PASSWORD_FILE"
    )
  fi
fi

set -e
step ca init "${step_ca_init_args[@]}"
cp "$STEP_PASSWORD_FILE" /home/step/secrets/password
