#!/bin/sh
#
# Runs as the step-ca-bootstrap Job. Either restores previously-backed-up
# CA material from the step-ca-restore Secret (if present - the
# disaster-recovery path: an operator creates that Secret from an offline
# backup copy before running this Job), or generates a fresh RSA
# root/intermediate CA pair and two passwords. Either way, the result
# lands in the step-ca-bootstrap-* Secrets, for the PushSecrets alongside
# this Job to copy into the real external store.
#
# The root key's password is independent of STEP_PASSWORD: the root key
# is only ever used transiently, to sign/replace the intermediate during
# `step ca init`. STEP_PASSWORD is what step-ca uses continuously -
# protecting the intermediate key at rest and authenticating remote
# administration - so the intermediate key is encrypted with
# STEP_PASSWORD specifically, not the root's password.

set -eu

namespace="${NAMESPACE:?NAMESPACE is required}"
ca_name="${STEP_CA_NAME:-Mass Open Cloud}"
restore_secret=step-ca-restore
workdir=$(mktemp -d)

echo "fetching kubectl" >&2
kubectl_version=$(curl -sL https://dl.k8s.io/release/stable.txt)
curl -sLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${kubectl_version}/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

get_field() {
  kubectl -n "$namespace" get secret "$restore_secret" -o go-template="{{index .data \"$1\"}}" | base64 -d
}

if kubectl -n "$namespace" get secret "$restore_secret" >/dev/null 2>&1; then
  echo "found $restore_secret - restoring supplied CA material instead of generating" >&2
  for f in root_ca.crt root_ca.key root_password intermediate_ca.crt intermediate_ca.key step_password; do
    get_field "$f" >"$workdir/$f"
  done
else
  echo "no $restore_secret found - generating fresh CA material" >&2

  step crypto rand 32 >"$workdir/root_password"
  step crypto rand 32 >"$workdir/step_password"

  step certificate create "$ca_name Root CA" \
    "$workdir/root_ca.crt" "$workdir/root_ca.key" \
    --profile root-ca \
    --kty RSA --size 4096 \
    --not-after 87600h \
    --password-file "$workdir/root_password" \
    --force

  step certificate create "$ca_name Intermediate CA" \
    "$workdir/intermediate_ca.crt" "$workdir/intermediate_ca.key" \
    --profile intermediate-ca \
    --ca "$workdir/root_ca.crt" --ca-key "$workdir/root_ca.key" --ca-password-file "$workdir/root_password" \
    --kty RSA --size 4096 \
    --not-after 43800h \
    --password-file "$workdir/step_password" \
    --force
fi

echo "writing step-ca-bootstrap-* secrets" >&2

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: step-ca-bootstrap-password
  namespace: $namespace
type: Opaque
data:
  STEP_PASSWORD: $(base64 -w0 <"$workdir/step_password")
EOF

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: step-ca-bootstrap-root-certificate
  namespace: $namespace
type: kubernetes.io/tls
data:
  tls.crt: $(base64 -w0 <"$workdir/root_ca.crt")
  tls.key: $(base64 -w0 <"$workdir/root_ca.key")
  password: $(base64 -w0 <"$workdir/root_password")
EOF

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: step-ca-bootstrap-intermediate-certificate
  namespace: $namespace
type: kubernetes.io/tls
data:
  tls.crt: $(base64 -w0 <"$workdir/intermediate_ca.crt")
  tls.key: $(base64 -w0 <"$workdir/intermediate_ca.key")
EOF

rm -rf "$workdir"
echo "done" >&2
