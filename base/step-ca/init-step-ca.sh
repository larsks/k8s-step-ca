#!/bin/bash

if [[ -z "$STEP_PASSWORD_FILE" ]]; then
  echo "ERROR: cannot continue without STEP_PASSWORD_FILE" >&2
  exit 1
fi

if [[ -f /home/step/config/ca.json ]]; then
  echo "CA already initialized, skipping step ca init" >&2
  exit 0
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
  IFS=',' read -r -a dns_names <<<"$STEP_DNS_NAMES"
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

# `step ca init` always generates an EC P-256 intermediate, even when given
# an RSA --root/--key: there is no flag to control the intermediate's key
# type. Dell iDRAC 8 requires every certificate in its trust chain -
# including the intermediate - to be RSA, so when we've been given our own
# pre-generated RSA intermediate, replace the one `step ca init` just
# created with it (the officially documented way to bring your own
# intermediate: https://smallstep.com/docs/tutorials/intermediate-ca-new-ca/).
if [[ -n "$STEP_CA_INTERMEDIATE_CERTIFICATE_FILE" ]]; then
  if [[ -z "$STEP_CA_INTERMEDIATE_KEY_FILE" ]]; then
    echo "ERROR: cannot use STEP_CA_INTERMEDIATE_CERTIFICATE_FILE without STEP_CA_INTERMEDIATE_KEY_FILE" >&2
    exit 1
  fi

  echo "replacing generated intermediate with provided RSA intermediate" >&2
  cp "$STEP_CA_INTERMEDIATE_CERTIFICATE_FILE" /home/step/certs/intermediate_ca.crt
  cp "$STEP_CA_INTERMEDIATE_KEY_FILE" /home/step/secrets/intermediate_ca_key
fi
