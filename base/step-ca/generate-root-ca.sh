#!/bin/bash
#
# generate-root-ca.sh [-n NAMESPACE] [-c COMMON_NAME] [-s KEY_SIZE] [-f]
#
# Operator tool: generates a new RSA root CA certificate/key with the
# `step` CLI, encrypts the key with a freshly generated random password,
# and applies it as the step-root-ca kubernetes.io/tls Secret (tls.crt,
# tls.key, password) - the material base/step-ca/init-step-ca.sh requires
# to exist before step-ca can initialize for the first time.
#
# Not part of the initContainer or any kustomize resource: this is run by
# hand, once, by whoever is standing up a new environment (or performing
# disaster recovery). Requires `step` and `kubectl` already on PATH,
# pointed at the right cluster/context.
#
# Dell iDRAC 8 requires an all-RSA trust chain, so the root is always RSA
# - there is no option to generate anything else.
#
# Refuses to overwrite an existing step-root-ca Secret unless -f is given:
# replacing the root silently would invalidate every certificate already
# issued from it.
set -euo pipefail

namespace=""
common_name="step-ca Root CA"
key_size=4096
force=0

usage() {
  cat <<EOF >&2
Usage: $0 [-n NAMESPACE] [-c COMMON_NAME] [-s KEY_SIZE] [-f]

  -n NAMESPACE    namespace to create the step-root-ca Secret in
                  (default: kubectl's current context namespace)
  -c COMMON_NAME  root certificate common name (default: "$common_name")
  -s KEY_SIZE     RSA key size in bits (default: $key_size)
  -f              overwrite an existing step-root-ca Secret
EOF
  exit 1
}

while getopts ":n:c:s:fh" opt; do
  case "$opt" in
  n) namespace="$OPTARG" ;;
  c) common_name="$OPTARG" ;;
  s) key_size="$OPTARG" ;;
  f) force=1 ;;
  h | *) usage ;;
  esac
done

if [[ -z "$namespace" ]]; then
  namespace="$(kubectl config view --minify -o jsonpath='{..namespace}')"
  if [[ -z "$namespace" ]]; then
    echo "no namespace given and no namespace set in the current kubectl context" >&2
    exit 1
  fi
fi

if ((force == 0)) && kubectl -n "$namespace" get secret step-root-ca >/dev/null 2>&1; then
  echo "step-root-ca already exists in namespace $namespace -" \
    "pass -f to overwrite it (this invalidates every certificate issued from the current root)" >&2
  exit 1
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

crt="$workdir/root_ca.crt"
key="$workdir/root_ca.key"
password_file="$workdir/root_ca_password"

step crypto rand 32 >"$password_file"

step certificate create "$common_name" "$crt" "$key" \
  --profile root-ca \
  --kty RSA --size "$key_size" \
  --password-file "$password_file" \
  --force

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: step-root-ca
  namespace: $namespace
type: kubernetes.io/tls
data:
  tls.crt: $(base64 -w0 <"$crt")
  tls.key: $(base64 -w0 <"$key")
  password: $(base64 -w0 <"$password_file")
EOF

echo "step-root-ca created in namespace $namespace" >&2
