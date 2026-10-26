bats_require_minimum_version 1.5.0

setup() {
  load_fixture_ca_json
  setup_fake_kubectl
  source_script
}

# source_script: (re-)sources init-step-ca.sh, then replaces fetch_kubectl
# with a stub that returns the fake kubectl instead of downloading a real
# one, so main() can be exercised end-to-end offline. fetch_kubectl itself
# is tested separately against a fake curl. Re-run by tests that override
# another function and need to restore the real one afterwards.
source_script() {
  source "$BATS_TEST_DIRNAME/../base/step-ca/init-step-ca.sh"
  fetch_kubectl() { echo "$BATS_TEST_TMPDIR/bin/kubectl"; }
}

setup_fake_kubectl() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cp "$BATS_TEST_DIRNAME/fixtures/fake-kubectl.sh" "$BATS_TEST_TMPDIR/bin/kubectl"
  chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
  export FAKE_KUBECTL_SECRETS_DIR="$BATS_TEST_TMPDIR/secrets"
  export FAKE_KUBECTL_LOG="$BATS_TEST_TMPDIR/kubectl.log"
  mkdir -p "$FAKE_KUBECTL_SECRETS_DIR"
}

# generate_test_root: writes a password-protected RSA root key/cert to
# $BATS_TEST_TMPDIR, for tests that only need a root (not a pre-built
# intermediate) - i.e. ensure_server_ca, which builds its own
# intermediate from this root.
generate_test_root() {
  local dir="$1"
  echo -n "rootpass" >"$dir/root_password"
  step certificate create "Test Root CA" \
    "$dir/root_ca.crt" "$dir/root_ca.key" \
    --profile root-ca --kty=RSA --size=2048 \
    --password-file "$dir/root_password" >/dev/null 2>&1
}

load_fixture_ca_json() {
  cat >"$BATS_TEST_TMPDIR/ca.json" <<'EOF'
{
  "root": "/home/step/certs/root_ca.crt",
  "authority": {
    "provisioners": []
  }
}
EOF
}

# generate_test_root_and_intermediate: writes a password-protected RSA root
# key/cert and a password-protected RSA intermediate key/cert (signed by
# that root, its key encrypted with intermediate_password) to
# $BATS_TEST_TMPDIR, plus a server provisioner password file. Used by
# tests that exercise run_step_ca_init against a real `step` binary.
generate_test_root_and_intermediate() {
  echo -n "rootpass" >"$BATS_TEST_TMPDIR/root_password"
  echo -n "serverpass" >"$BATS_TEST_TMPDIR/server_password"
  echo -n "interpass" >"$BATS_TEST_TMPDIR/intermediate_password"

  step certificate create "Test Root CA" \
    "$BATS_TEST_TMPDIR/root_ca.crt" "$BATS_TEST_TMPDIR/root_ca.key" \
    --profile root-ca --kty=RSA --size=2048 \
    --password-file "$BATS_TEST_TMPDIR/root_password" >/dev/null 2>&1

  step certificate create "Test Intermediate CA" \
    "$BATS_TEST_TMPDIR/intermediate_ca.crt" "$BATS_TEST_TMPDIR/intermediate_ca.key" \
    --profile intermediate-ca \
    --ca "$BATS_TEST_TMPDIR/root_ca.crt" --ca-key "$BATS_TEST_TMPDIR/root_ca.key" \
    --ca-password-file "$BATS_TEST_TMPDIR/root_password" \
    --kty=RSA --size=2048 \
    --password-file "$BATS_TEST_TMPDIR/intermediate_password" >/dev/null 2>&1
}

# init_test_ca: runs run_step_ca_init against $BATS_TEST_TMPDIR/config using
# the fixtures from generate_test_root_and_intermediate. Used by tests that
# need an already-initialized ca.json to add provisioners to.
init_test_ca() {
  generate_test_root_and_intermediate
  run_step_ca_init "$BATS_TEST_TMPDIR/config" "Test CA" "ca.example.com" server \
    "$BATS_TEST_TMPDIR/server_password" \
    "$BATS_TEST_TMPDIR/root_ca.crt" "$BATS_TEST_TMPDIR/root_ca.key" "$BATS_TEST_TMPDIR/root_password" \
    "$BATS_TEST_TMPDIR/intermediate_ca.crt" "$BATS_TEST_TMPDIR/intermediate_ca.key" \
    "$BATS_TEST_TMPDIR/intermediate_password"
}

# setup_main_env: writes an operator-supplied RSA step-root-ca to
# $BATS_TEST_TMPDIR/root-ca and exports the environment main() reads, so a
# test can just `run main`. TMPDIR is pointed at an empty directory so
# tests can check that main()'s scratch workdir is cleaned up.
setup_main_env() {
  mkdir -p "$BATS_TEST_TMPDIR/root-ca" "$BATS_TEST_TMPDIR/tmp"
  generate_test_root "$BATS_TEST_TMPDIR"
  cp "$BATS_TEST_TMPDIR/root_ca.crt" "$BATS_TEST_TMPDIR/root-ca/tls.crt"
  cp "$BATS_TEST_TMPDIR/root_ca.key" "$BATS_TEST_TMPDIR/root-ca/tls.key"
  cp "$BATS_TEST_TMPDIR/root_password" "$BATS_TEST_TMPDIR/root-ca/password"
  export STEP_CONFIG_DIR="$BATS_TEST_TMPDIR/config"
  export STEP_ROOT_CA_DIR="$BATS_TEST_TMPDIR/root-ca"
  export NAMESPACE=step-ca
  export STEP_DNS_NAMES=ca.example.com
  export STEP_POLICY_ALLOW_DNS='*.example.com'
  export STEP_POLICY_ALLOW_IP=10.0.0.0/8
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
}

# setup_fake_curl: installs a `curl` stub on PATH that serves files from
# $BATS_TEST_TMPDIR/dl by URL basename (stable.txt, kubectl,
# kubectl.sha256), exiting 22 (curl's -f HTTP-error status) for anything
# absent. Each invocation's arguments are logged to curl.log.
setup_fake_curl() {
  mkdir -p "$BATS_TEST_TMPDIR/curlbin" "$BATS_TEST_TMPDIR/dl"
  cat >"$BATS_TEST_TMPDIR/curlbin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
out=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  -*o) out="$2"; shift ;;
  -*) ;;
  *) url="$1" ;;
  esac
  shift
done
src="$FAKE_CURL_DIR/${url##*/}"
[[ -f "$src" ]] || exit 22
if [[ -n "$out" ]]; then cp "$src" "$out"; else cat "$src"; fi
EOF
  chmod +x "$BATS_TEST_TMPDIR/curlbin/curl"
  export FAKE_CURL_DIR="$BATS_TEST_TMPDIR/dl"
  export FAKE_CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  echo "v1.31.0" >"$FAKE_CURL_DIR/stable.txt"
  printf '#!/bin/sh\necho fake\n' >"$FAKE_CURL_DIR/kubectl"
  sha256sum "$FAKE_CURL_DIR/kubectl" | cut -d' ' -f1 >"$FAKE_CURL_DIR/kubectl.sha256"
  # Undo source_script's stub: these tests exercise the real fetch_kubectl.
  source "$BATS_TEST_DIRNAME/../base/step-ca/init-step-ca.sh"
}

@test "apply_authority_policy sets dns and ip allow lists" {
  apply_authority_policy "$BATS_TEST_TMPDIR/ca.json" '*.massopen.cloud' '10.0.0.0/8' '2160h'
  run jq -r '.authority.policy.x509.allow.dns[0]' "$BATS_TEST_TMPDIR/ca.json"
  [ "$output" = '*.massopen.cloud' ]
  run jq -r '.authority.policy.x509.allow.ip[0]' "$BATS_TEST_TMPDIR/ca.json"
  [ "$output" = '10.0.0.0/8' ]
}

@test "apply_authority_policy sets default cert duration" {
  apply_authority_policy "$BATS_TEST_TMPDIR/ca.json" '*.massopen.cloud' '10.0.0.0/8' '2160h'
  run jq -r '.authority.claims.defaultTLSCertDuration' "$BATS_TEST_TMPDIR/ca.json"
  [ "$output" = '2160h' ]
}

@test "apply_authority_policy is idempotent when re-run" {
  apply_authority_policy "$BATS_TEST_TMPDIR/ca.json" '*.massopen.cloud' '10.0.0.0/8' '2160h'
  apply_authority_policy "$BATS_TEST_TMPDIR/ca.json" '*.massopen.cloud' '10.0.0.0/8' '2160h'
  run jq -r '.authority.policy.x509.allow.dns | length' "$BATS_TEST_TMPDIR/ca.json"
  [ "$output" = '1' ]
  run jq -r '.authority.policy.x509.allow.ip | length' "$BATS_TEST_TMPDIR/ca.json"
  [ "$output" = '1' ]
}

@test "apply_authority_policy preserves unrelated ca.json keys" {
  apply_authority_policy "$BATS_TEST_TMPDIR/ca.json" '*.massopen.cloud' '10.0.0.0/8' '2160h'
  run jq -r '.root' "$BATS_TEST_TMPDIR/ca.json"
  [ "$output" = '/home/step/certs/root_ca.crt' ]
}

@test "run_step_ca_init produces ca.json with an RSA intermediate" {
  init_test_ca
  run openssl x509 -in "$BATS_TEST_TMPDIR/config/certs/intermediate_ca.crt" -noout -text
  [[ "$output" == *"rsaEncryption"* ]]
}

@test "run_step_ca_init copies the server CA key password (not the provisioner password) to secrets/password" {
  init_test_ca
  run diff "$BATS_TEST_TMPDIR/intermediate_password" "$BATS_TEST_TMPDIR/config/secrets/password"
  [ "$status" -eq 0 ]
  # ...and it actually decrypts the intermediate key the server will load.
  run openssl rsa -in "$BATS_TEST_TMPDIR/config/secrets/intermediate_ca_key" \
    -passin "file:$BATS_TEST_TMPDIR/config/secrets/password" -check -noout
  [ "$status" -eq 0 ]
}

@test "run_step_ca_init makes secrets/password and secrets/intermediate_ca_key mode 0600" {
  init_test_ca
  run stat -c '%a' "$BATS_TEST_TMPDIR/config/secrets/password"
  [ "$output" = "600" ]
  run stat -c '%a' "$BATS_TEST_TMPDIR/config/secrets/intermediate_ca_key"
  [ "$output" = "600" ]
}

@test "run_step_ca_init produces a ca.json with the requested sole provisioner" {
  init_test_ca
  run jq -r '.authority.provisioners[].name' "$BATS_TEST_TMPDIR/config/config/ca.json"
  [ "$output" = "server" ]
}

@test "run_step_ca_init succeeds over the leftovers of an earlier partial run" {
  init_test_ca
  add_acme_provisioner "$BATS_TEST_TMPDIR/config/config/ca.json" acme
  run run_step_ca_init "$BATS_TEST_TMPDIR/config" "Test CA" "ca.example.com" server \
    "$BATS_TEST_TMPDIR/server_password" \
    "$BATS_TEST_TMPDIR/root_ca.crt" "$BATS_TEST_TMPDIR/root_ca.key" "$BATS_TEST_TMPDIR/root_password" \
    "$BATS_TEST_TMPDIR/intermediate_ca.crt" "$BATS_TEST_TMPDIR/intermediate_ca.key" \
    "$BATS_TEST_TMPDIR/intermediate_password"
  [ "$status" -eq 0 ]
  run jq -r '.authority.provisioners[].name' "$BATS_TEST_TMPDIR/config/config/ca.json"
  [ "$output" = "server" ]
}

@test "add_idrac_provisioner adds a JWK provisioner with the RSA-only template" {
  init_test_ca
  echo -n "idracpass" >"$BATS_TEST_TMPDIR/idrac_password"
  add_idrac_provisioner "$BATS_TEST_TMPDIR/config/config/ca.json" idrac \
    "$BATS_TEST_TMPDIR/idrac_password" "$BATS_TEST_DIRNAME/../base/step-ca/idrac-rsa.tpl"
  run jq -e '.authority.provisioners[] | select(.name == "idrac" and .type == "JWK")' \
    "$BATS_TEST_TMPDIR/config/config/ca.json"
  [ "$status" -eq 0 ]
  # `step ca provisioner update --x509-template` inlines the template's
  # contents into .options.x509.template; the step CLI has no mechanism to
  # instead record a templateFile path. Assert on the content it actually
  # writes.
  run jq -r '.authority.provisioners[] | select(.name == "idrac") | .options.x509.template' \
    "$BATS_TEST_TMPDIR/config/config/ca.json"
  [[ "$output" == *"iDRAC devices do not support EC/Ed25519"* ]]
}

@test "add_acme_provisioner adds an ACME provisioner" {
  init_test_ca
  add_acme_provisioner "$BATS_TEST_TMPDIR/config/config/ca.json" acme
  run jq -e '.authority.provisioners[] | select(.name == "acme" and .type == "ACME")' \
    "$BATS_TEST_TMPDIR/config/config/ca.json"
  [ "$status" -eq 0 ]
}

@test "ca_already_initialized returns false when nothing is present" {
  run ca_already_initialized "$BATS_TEST_TMPDIR/config"
  [ "$status" -ne 0 ]
}

@test "ca_already_initialized returns false when ca.json is present without the completion marker" {
  mkdir -p "$BATS_TEST_TMPDIR/config/config"
  touch "$BATS_TEST_TMPDIR/config/config/ca.json"
  run ca_already_initialized "$BATS_TEST_TMPDIR/config"
  [ "$status" -ne 0 ]
}

@test "ca_already_initialized returns true when the completion marker is present" {
  mkdir -p "$BATS_TEST_TMPDIR/config/config"
  touch "$BATS_TEST_TMPDIR/config/config/ca.json"
  touch "$(init_marker "$BATS_TEST_TMPDIR/config")"
  run ca_already_initialized "$BATS_TEST_TMPDIR/config"
  [ "$status" -eq 0 ]
}

@test "root_is_rsa accepts an RSA certificate" {
  generate_test_root "$BATS_TEST_TMPDIR"
  run root_is_rsa "$BATS_TEST_TMPDIR/root_ca.crt"
  [ "$status" -eq 0 ]
}

@test "root_is_rsa rejects an EC certificate" {
  step certificate create "EC Root" "$BATS_TEST_TMPDIR/ec.crt" "$BATS_TEST_TMPDIR/ec.key" \
    --profile root-ca --kty=EC --no-password --insecure >/dev/null 2>&1
  run root_is_rsa "$BATS_TEST_TMPDIR/ec.crt"
  [ "$status" -ne 0 ]
}

@test "fake kubectl mirrors real kubectl's <no value> output for a bare index template" {
  mkdir -p "$BATS_TEST_TMPDIR/secrets/step-server-ca"
  run "$BATS_TEST_TMPDIR/bin/kubectl" -n step-ca get secret step-server-ca \
    -o 'go-template={{index .data "tls.key"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "<no value>" ]
}

@test "secret_field returns 1 when the secret is absent" {
  run secret_field "$BATS_TEST_TMPDIR/bin/kubectl" step-ca step-server-ca tls.crt
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "secret_field prints the decoded field when present" {
  mkdir -p "$BATS_TEST_TMPDIR/secrets/step-server-ca"
  printf 'hello world' >"$BATS_TEST_TMPDIR/secrets/step-server-ca/tls.crt"
  run secret_field "$BATS_TEST_TMPDIR/bin/kubectl" step-ca step-server-ca tls.crt
  [ "$status" -eq 0 ]
  [ "$output" = "hello world" ]
}

@test "secret_field returns 1 when the secret exists but the field is missing" {
  mkdir -p "$BATS_TEST_TMPDIR/secrets/step-server-ca"
  printf 'hello world' >"$BATS_TEST_TMPDIR/secrets/step-server-ca/tls.crt"
  run secret_field "$BATS_TEST_TMPDIR/bin/kubectl" step-ca step-server-ca tls.key
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "secret_field returns 1 when the field is present but empty" {
  mkdir -p "$BATS_TEST_TMPDIR/secrets/step-server-ca"
  : >"$BATS_TEST_TMPDIR/secrets/step-server-ca/tls.key"
  run secret_field "$BATS_TEST_TMPDIR/bin/kubectl" step-ca step-server-ca tls.key
  [ "$status" -eq 1 ]
}

@test "secret_field returns 2 when the API lookup itself fails" {
  mkdir -p "$BATS_TEST_TMPDIR/secrets/step-server-ca"
  printf 'hello world' >"$BATS_TEST_TMPDIR/secrets/step-server-ca/tls.crt"
  FAKE_KUBECTL_GET_FAILS=1 run secret_field "$BATS_TEST_TMPDIR/bin/kubectl" step-ca step-server-ca tls.crt
  [ "$status" -eq 2 ]
}

@test "secret_field returns 2 when the field is not valid base64" {
  cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'EOF'
#!/bin/bash
printf '<no value>'
EOF
  run secret_field "$BATS_TEST_TMPDIR/bin/kubectl" step-ca step-server-ca tls.crt
  [ "$status" -eq 2 ]
}

@test "ensure_server_ca generates and stores a complete secret when absent" {
  generate_test_root "$BATS_TEST_TMPDIR"
  run --separate-stderr ensure_server_ca "$BATS_TEST_TMPDIR/bin/kubectl" step-ca "$BATS_TEST_TMPDIR/work" \
    "$BATS_TEST_TMPDIR/root_ca.crt" "$BATS_TEST_TMPDIR/root_ca.key" "$BATS_TEST_TMPDIR/root_password"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$BATS_TEST_TMPDIR/work/server_ca.crt" ]
  [ "${lines[1]}" = "$BATS_TEST_TMPDIR/work/server_ca.key" ]
  [ "${lines[2]}" = "$BATS_TEST_TMPDIR/work/server_ca_password" ]
  [ "${#lines[@]}" -eq 3 ]
  [ -s "$BATS_TEST_TMPDIR/secrets/step-server-ca/tls.crt" ]
  [ -s "$BATS_TEST_TMPDIR/secrets/step-server-ca/tls.key" ]
  [ -s "$BATS_TEST_TMPDIR/secrets/step-server-ca/password" ]
}

@test "ensure_server_ca encrypts the generated key with the generated password" {
  generate_test_root "$BATS_TEST_TMPDIR"
  run --separate-stderr ensure_server_ca "$BATS_TEST_TMPDIR/bin/kubectl" step-ca "$BATS_TEST_TMPDIR/work" \
    "$BATS_TEST_TMPDIR/root_ca.crt" "$BATS_TEST_TMPDIR/root_ca.key" "$BATS_TEST_TMPDIR/root_password"
  [ "$status" -eq 0 ]
  local secret="$BATS_TEST_TMPDIR/secrets/step-server-ca"
  # Encrypted: no password, no key.
  run openssl rsa -in "$secret/tls.key" -passin pass: -check -noout
  [ "$status" -ne 0 ]
  # The stored password decrypts the stored key...
  run openssl rsa -in "$secret/tls.key" -passin "file:$secret/password" -check -noout
  [ "$status" -eq 0 ]
  # ...and the password handed to the caller is that same password.
  run diff "$secret/password" "$BATS_TEST_TMPDIR/work/server_ca_password"
  [ "$status" -eq 0 ]
}

@test "ensure_server_ca does not overwrite an existing complete secret, and writes its values to workdir" {
  mkdir -p "$BATS_TEST_TMPDIR/secrets/step-server-ca"
  echo "existing-crt" >"$BATS_TEST_TMPDIR/secrets/step-server-ca/tls.crt"
  echo "existing-key" >"$BATS_TEST_TMPDIR/secrets/step-server-ca/tls.key"
  echo -n "existing-password" >"$BATS_TEST_TMPDIR/secrets/step-server-ca/password"
  run --separate-stderr ensure_server_ca "$BATS_TEST_TMPDIR/bin/kubectl" step-ca "$BATS_TEST_TMPDIR/work" \
    "$BATS_TEST_TMPDIR/root_ca.crt" "$BATS_TEST_TMPDIR/root_ca.key" "$BATS_TEST_TMPDIR/root_password"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$BATS_TEST_TMPDIR/work/server_ca.crt" ]
  [ "${lines[1]}" = "$BATS_TEST_TMPDIR/work/server_ca.key" ]
  [ "${lines[2]}" = "$BATS_TEST_TMPDIR/work/server_ca_password" ]
  run cat "$BATS_TEST_TMPDIR/work/server_ca.crt"
  [ "$output" = "existing-crt" ]
  run cat "$BATS_TEST_TMPDIR/work/server_ca.key"
  [ "$output" = "existing-key" ]
  run cat "$BATS_TEST_TMPDIR/work/server_ca_password"
  [ "$output" = "existing-password" ]
  run cat "$BATS_TEST_TMPDIR/secrets/step-server-ca/tls.crt"
  [ "$output" = "existing-crt" ]
  run grep -c '^apply' "$BATS_TEST_TMPDIR/kubectl.log"
  [ "$output" = "0" ]
}

@test "ensure_server_ca regenerates when the secret exists but tls.key is missing" {
  generate_test_root "$BATS_TEST_TMPDIR"
  mkdir -p "$BATS_TEST_TMPDIR/secrets/step-server-ca"
  echo "existing-crt" >"$BATS_TEST_TMPDIR/secrets/step-server-ca/tls.crt"
  run --separate-stderr ensure_server_ca "$BATS_TEST_TMPDIR/bin/kubectl" step-ca "$BATS_TEST_TMPDIR/work" \
    "$BATS_TEST_TMPDIR/root_ca.crt" "$BATS_TEST_TMPDIR/root_ca.key" "$BATS_TEST_TMPDIR/root_password"
  [ "$status" -eq 0 ]
  run openssl x509 -in "$BATS_TEST_TMPDIR/secrets/step-server-ca/tls.crt" -noout -subject
  [[ "$output" == *"step-ca Server CA"* ]]
  [ -s "$BATS_TEST_TMPDIR/secrets/step-server-ca/tls.key" ]
}

@test "ensure_server_ca fails without overwriting when tls.crt/tls.key exist but password is missing" {
  mkdir -p "$BATS_TEST_TMPDIR/secrets/step-server-ca"
  echo "existing-crt" >"$BATS_TEST_TMPDIR/secrets/step-server-ca/tls.crt"
  echo "existing-key" >"$BATS_TEST_TMPDIR/secrets/step-server-ca/tls.key"
  run --separate-stderr ensure_server_ca "$BATS_TEST_TMPDIR/bin/kubectl" step-ca "$BATS_TEST_TMPDIR/work" \
    "$BATS_TEST_TMPDIR/root_ca.crt" "$BATS_TEST_TMPDIR/root_ca.key" "$BATS_TEST_TMPDIR/root_password"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"no password"* ]]
  run cat "$BATS_TEST_TMPDIR/secrets/step-server-ca/tls.crt"
  [ "$output" = "existing-crt" ]
}

@test "ensure_server_ca fails without generating when the API lookup fails" {
  generate_test_root "$BATS_TEST_TMPDIR"
  FAKE_KUBECTL_GET_FAILS=1 run --separate-stderr ensure_server_ca "$BATS_TEST_TMPDIR/bin/kubectl" step-ca "$BATS_TEST_TMPDIR/work" \
    "$BATS_TEST_TMPDIR/root_ca.crt" "$BATS_TEST_TMPDIR/root_ca.key" "$BATS_TEST_TMPDIR/root_password"
  [ "$status" -ne 0 ]
  run grep -c '^apply' "$BATS_TEST_TMPDIR/kubectl.log"
  [ "$output" = "0" ]
}

@test "ensure_provisioner_password generates and stores a secret when absent" {
  run --separate-stderr ensure_provisioner_password "$BATS_TEST_TMPDIR/bin/kubectl" step-ca "$BATS_TEST_TMPDIR/work" server
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/work/server_password" ]
  [ -s "$BATS_TEST_TMPDIR/secrets/step-provisioner-server/password" ]
  run diff "$BATS_TEST_TMPDIR/secrets/step-provisioner-server/password" "$BATS_TEST_TMPDIR/work/server_password"
  [ "$status" -eq 0 ]
}

@test "ensure_provisioner_password does not overwrite an existing secret, and writes its value to workdir" {
  mkdir -p "$BATS_TEST_TMPDIR/secrets/step-provisioner-server"
  echo -n "existing-password" >"$BATS_TEST_TMPDIR/secrets/step-provisioner-server/password"
  run --separate-stderr ensure_provisioner_password "$BATS_TEST_TMPDIR/bin/kubectl" step-ca "$BATS_TEST_TMPDIR/work" server
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/work/server_password" ]
  run cat "$BATS_TEST_TMPDIR/work/server_password"
  [ "$output" = "existing-password" ]
  run cat "$BATS_TEST_TMPDIR/secrets/step-provisioner-server/password"
  [ "$output" = "existing-password" ]
}

@test "ensure_provisioner_password generates when the secret exists but has no password field" {
  mkdir -p "$BATS_TEST_TMPDIR/secrets/step-provisioner-server"
  echo -n "something" >"$BATS_TEST_TMPDIR/secrets/step-provisioner-server/wrong-field"
  run --separate-stderr ensure_provisioner_password "$BATS_TEST_TMPDIR/bin/kubectl" step-ca "$BATS_TEST_TMPDIR/work" server
  [ "$status" -eq 0 ]
  [ -s "$BATS_TEST_TMPDIR/secrets/step-provisioner-server/password" ]
  run diff "$BATS_TEST_TMPDIR/secrets/step-provisioner-server/password" "$BATS_TEST_TMPDIR/work/server_password"
  [ "$status" -eq 0 ]
}

@test "ensure_provisioner_password fails without generating when the API lookup fails" {
  FAKE_KUBECTL_GET_FAILS=1 run --separate-stderr ensure_provisioner_password "$BATS_TEST_TMPDIR/bin/kubectl" step-ca \
    "$BATS_TEST_TMPDIR/work" server
  [ "$status" -ne 0 ]
  run grep -c '^apply' "$BATS_TEST_TMPDIR/kubectl.log"
  [ "$output" = "0" ]
}

@test "fetch_kubectl downloads and verifies kubectl" {
  setup_fake_curl
  PATH="$BATS_TEST_TMPDIR/curlbin:$PATH" run --separate-stderr fetch_kubectl "$BATS_TEST_TMPDIR/work"
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/work/kubectl" ]
  [ -x "$BATS_TEST_TMPDIR/work/kubectl" ]
  # Every request fails on HTTP errors rather than saving the error page.
  run grep -vc -- '^-f' "$FAKE_CURL_LOG"
  [ "$output" = "0" ]
  run grep -c 'kubectl.sha256$' "$FAKE_CURL_LOG"
  [ "$output" = "1" ]
}

@test "fetch_kubectl fails and discards the binary on a checksum mismatch" {
  setup_fake_curl
  echo "0000000000000000000000000000000000000000000000000000000000000000" >"$FAKE_CURL_DIR/kubectl.sha256"
  PATH="$BATS_TEST_TMPDIR/curlbin:$PATH" run --separate-stderr fetch_kubectl "$BATS_TEST_TMPDIR/work"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"sha256 mismatch"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/work/kubectl" ]
}

@test "fetch_kubectl fails when the checksum can't be downloaded" {
  setup_fake_curl
  rm "$FAKE_CURL_DIR/kubectl.sha256"
  PATH="$BATS_TEST_TMPDIR/curlbin:$PATH" run --separate-stderr fetch_kubectl "$BATS_TEST_TMPDIR/work"
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/work/kubectl" ]
}

@test "fetch_kubectl fails when the binary download fails" {
  setup_fake_curl
  rm "$FAKE_CURL_DIR/kubectl"
  PATH="$BATS_TEST_TMPDIR/curlbin:$PATH" run --separate-stderr fetch_kubectl "$BATS_TEST_TMPDIR/work"
  [ "$status" -ne 0 ]
  [ ! -x "$BATS_TEST_TMPDIR/work/kubectl" ]
}

@test "main exits 0 immediately when the completion marker exists, without touching secrets" {
  mkdir -p "$BATS_TEST_TMPDIR/config/config"
  touch "$BATS_TEST_TMPDIR/config/config/ca.json"
  touch "$(init_marker "$BATS_TEST_TMPDIR/config")"
  STEP_CONFIG_DIR="$BATS_TEST_TMPDIR/config" run main
  [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/kubectl.log" ]
}

@test "main fails with a clear message when not initialized and the root key is unavailable" {
  mkdir -p "$BATS_TEST_TMPDIR/config"
  mkdir -p "$BATS_TEST_TMPDIR/root-ca"
  echo "cert-only" >"$BATS_TEST_TMPDIR/root-ca/tls.crt" # tls.key/password deliberately absent
  STEP_CONFIG_DIR="$BATS_TEST_TMPDIR/config" STEP_ROOT_CA_DIR="$BATS_TEST_TMPDIR/root-ca" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"restore"*"step-root-ca"* ]]
  [ ! -f "$BATS_TEST_TMPDIR/kubectl.log" ]
}

@test "main fails with a clear message when step-root-ca is not RSA, before touching secrets or step ca init" {
  setup_main_env
  echo -n "rootpass" >"$BATS_TEST_TMPDIR/root-ca/password"
  step certificate create "EC Root" "$BATS_TEST_TMPDIR/root-ca/tls.crt" "$BATS_TEST_TMPDIR/root-ca/tls.key" \
    --profile root-ca --kty=EC --password-file "$BATS_TEST_TMPDIR/root-ca/password" --force >/dev/null 2>&1
  run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"not an RSA certificate"* ]]
  [ ! -f "$BATS_TEST_TMPDIR/kubectl.log" ]
  [ ! -e "$BATS_TEST_TMPDIR/config/config/ca.json" ]
}

@test "main initializes a complete CA and writes the completion marker" {
  setup_main_env
  run main
  [ "$status" -eq 0 ]
  local config="$BATS_TEST_TMPDIR/config"
  [ -f "$(init_marker "$config")" ]
  run jq -r '[.authority.provisioners[].name] | join(",")' "$config/config/ca.json"
  [ "$output" = "server,idrac,acme" ]
  run jq -r '.authority.policy.x509.allow.dns[0]' "$config/config/ca.json"
  [ "$output" = '*.example.com' ]
  # The server's startup password decrypts the RSA intermediate it loads,
  # and both match what was stored in step-server-ca.
  run openssl rsa -in "$config/secrets/intermediate_ca_key" \
    -passin "file:$config/secrets/password" -check -noout
  [ "$status" -eq 0 ]
  run diff "$BATS_TEST_TMPDIR/secrets/step-server-ca/password" "$config/secrets/password"
  [ "$status" -eq 0 ]
  run diff "$BATS_TEST_TMPDIR/secrets/step-server-ca/tls.crt" "$config/certs/intermediate_ca.crt"
  [ "$status" -eq 0 ]
  [ -s "$BATS_TEST_TMPDIR/secrets/step-provisioner-server/password" ]
  [ -s "$BATS_TEST_TMPDIR/secrets/step-provisioner-idrac/password" ]
}

@test "main removes its scratch workdir on exit" {
  setup_main_env
  run main
  [ "$status" -eq 0 ]
  run ls -A "$BATS_TEST_TMPDIR/tmp"
  [ -z "$output" ]
}

@test "main retries in full after a failure that left ca.json behind" {
  setup_main_env
  local config="$BATS_TEST_TMPDIR/config"

  add_idrac_provisioner() { return 1; }
  run main
  [ "$status" -ne 0 ]
  [ -f "$config/config/ca.json" ]
  [ ! -f "$(init_marker "$config")" ]

  # The failure is gone; the next pod start must not accept the half-built
  # ca.json, but redo initialization and finish it.
  source_script
  run main
  [ "$status" -eq 0 ]
  [[ "$output" != *"skipping initialization"* ]]
  [[ "$output" == *"did not complete"* ]]
  [ -f "$(init_marker "$config")" ]
  run jq -r '[.authority.provisioners[].name] | join(",")' "$config/config/ca.json"
  [ "$output" = "server,idrac,acme" ]
  run jq -e '.authority.policy.x509.allow.ip[0] == "10.0.0.0/8"' "$config/config/ca.json"
  [ "$status" -eq 0 ]
}

@test "main reuses secrets generated by an earlier failed attempt" {
  setup_main_env
  add_acme_provisioner() { return 1; }
  run main
  [ "$status" -ne 0 ]
  cp "$BATS_TEST_TMPDIR/secrets/step-server-ca/tls.crt" "$BATS_TEST_TMPDIR/first_server_ca.crt"

  source_script
  run main
  [ "$status" -eq 0 ]
  run diff "$BATS_TEST_TMPDIR/first_server_ca.crt" "$BATS_TEST_TMPDIR/config/certs/intermediate_ca.crt"
  [ "$status" -eq 0 ]
}
