setup() {
  load_fixture_ca_json
  setup_fake_kubectl
  source "$BATS_TEST_DIRNAME/../base/step-ca/init-step-ca.sh"
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
    --password-file "$dir/root_password" >/dev/null
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
# that root) to $BATS_TEST_TMPDIR, plus a server provisioner password file.
# Used by tests that exercise run_step_ca_init against a real `step`
# binary.
generate_test_root_and_intermediate() {
  echo -n "rootpass" >"$BATS_TEST_TMPDIR/root_password"
  echo -n "serverpass" >"$BATS_TEST_TMPDIR/server_password"

  step certificate create "Test Root CA" \
    "$BATS_TEST_TMPDIR/root_ca.crt" "$BATS_TEST_TMPDIR/root_ca.key" \
    --profile root-ca --kty=RSA --size=2048 \
    --password-file "$BATS_TEST_TMPDIR/root_password" >/dev/null

  step certificate create "Test Intermediate CA" \
    "$BATS_TEST_TMPDIR/intermediate_ca.crt" "$BATS_TEST_TMPDIR/intermediate_ca.key" \
    --profile intermediate-ca \
    --ca "$BATS_TEST_TMPDIR/root_ca.crt" --ca-key "$BATS_TEST_TMPDIR/root_ca.key" \
    --ca-password-file "$BATS_TEST_TMPDIR/root_password" \
    --kty=RSA --size=2048 \
    --password-file "$BATS_TEST_TMPDIR/root_password" >/dev/null
}

# init_test_ca: runs run_step_ca_init against $BATS_TEST_TMPDIR/config using
# the fixtures from generate_test_root_and_intermediate. Used by tests that
# need an already-initialized ca.json to add provisioners to.
init_test_ca() {
  generate_test_root_and_intermediate
  run_step_ca_init "$BATS_TEST_TMPDIR/config" "Test CA" "ca.example.com" server \
    "$BATS_TEST_TMPDIR/server_password" \
    "$BATS_TEST_TMPDIR/root_ca.crt" "$BATS_TEST_TMPDIR/root_ca.key" "$BATS_TEST_TMPDIR/root_password" \
    "$BATS_TEST_TMPDIR/intermediate_ca.crt" "$BATS_TEST_TMPDIR/intermediate_ca.key"
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
  generate_test_root_and_intermediate
  run_step_ca_init "$BATS_TEST_TMPDIR/config" "Test CA" "ca.example.com" server \
    "$BATS_TEST_TMPDIR/server_password" \
    "$BATS_TEST_TMPDIR/root_ca.crt" "$BATS_TEST_TMPDIR/root_ca.key" "$BATS_TEST_TMPDIR/root_password" \
    "$BATS_TEST_TMPDIR/intermediate_ca.crt" "$BATS_TEST_TMPDIR/intermediate_ca.key"
  run openssl x509 -in "$BATS_TEST_TMPDIR/config/certs/intermediate_ca.crt" -noout -text
  [[ "$output" == *"rsaEncryption"* ]]
}

@test "run_step_ca_init copies the provisioner password to the canonical secrets/password path" {
  init_test_ca
  [ -f "$BATS_TEST_TMPDIR/config/secrets/password" ]
  run diff "$BATS_TEST_TMPDIR/server_password" "$BATS_TEST_TMPDIR/config/secrets/password"
  [ "$status" -eq 0 ]
}

@test "run_step_ca_init produces a ca.json with the requested sole provisioner" {
  init_test_ca
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

@test "ca_already_initialized returns false when ca.json is absent" {
  run ca_already_initialized "$BATS_TEST_TMPDIR/config"
  [ "$status" -ne 0 ]
}

@test "ca_already_initialized returns true when ca.json is present" {
  mkdir -p "$BATS_TEST_TMPDIR/config/config"
  touch "$BATS_TEST_TMPDIR/config/config/ca.json"
  run ca_already_initialized "$BATS_TEST_TMPDIR/config"
  [ "$status" -eq 0 ]
}

@test "secret_field returns non-zero when the secret is absent" {
  run secret_field "$BATS_TEST_TMPDIR/bin/kubectl" step-ca step-server-ca tls.crt "$BATS_TEST_TMPDIR/work"
  [ "$status" -ne 0 ]
}

@test "secret_field prints the decoded field when present" {
  mkdir -p "$BATS_TEST_TMPDIR/secrets/step-server-ca"
  printf 'hello world' >"$BATS_TEST_TMPDIR/secrets/step-server-ca/tls.crt"
  run secret_field "$BATS_TEST_TMPDIR/bin/kubectl" step-ca step-server-ca tls.crt "$BATS_TEST_TMPDIR/work"
  [ "$status" -eq 0 ]
  [ "$output" = "hello world" ]
}

@test "ensure_server_ca generates and stores a secret when absent" {
  generate_test_root "$BATS_TEST_TMPDIR" # writes root_ca.crt/key/password
  run ensure_server_ca "$BATS_TEST_TMPDIR/bin/kubectl" step-ca "$BATS_TEST_TMPDIR/work" \
    "$BATS_TEST_TMPDIR/root_ca.crt" "$BATS_TEST_TMPDIR/root_ca.key" "$BATS_TEST_TMPDIR/root_password"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/secrets/step-server-ca/tls.crt" ]
  [ -f "$BATS_TEST_TMPDIR/secrets/step-server-ca/tls.key" ]
}

@test "ensure_server_ca does not overwrite an existing secret" {
  mkdir -p "$BATS_TEST_TMPDIR/secrets/step-server-ca"
  echo "existing" >"$BATS_TEST_TMPDIR/secrets/step-server-ca/tls.crt"
  echo "existing" >"$BATS_TEST_TMPDIR/secrets/step-server-ca/tls.key"
  run ensure_server_ca "$BATS_TEST_TMPDIR/bin/kubectl" step-ca "$BATS_TEST_TMPDIR/work" \
    "$BATS_TEST_TMPDIR/root_ca.crt" "$BATS_TEST_TMPDIR/root_ca.key" "$BATS_TEST_TMPDIR/root_password"
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/secrets/step-server-ca/tls.crt"
  [ "$output" = "existing" ]
}

@test "ensure_server_ca prints the mounted path when the secret already exists" {
  mkdir -p "$BATS_TEST_TMPDIR/secrets/step-server-ca"
  echo "existing" >"$BATS_TEST_TMPDIR/secrets/step-server-ca/tls.crt"
  echo "existing" >"$BATS_TEST_TMPDIR/secrets/step-server-ca/tls.key"
  run ensure_server_ca "$BATS_TEST_TMPDIR/bin/kubectl" step-ca "$BATS_TEST_TMPDIR/work" \
    "$BATS_TEST_TMPDIR/root_ca.crt" "$BATS_TEST_TMPDIR/root_ca.key" "$BATS_TEST_TMPDIR/root_password"
  [ "$output" = "/step/server-ca/tls.crt:/step/server-ca/tls.key" ]
}

@test "ensure_provisioner_password generates and stores a secret when absent" {
  run ensure_provisioner_password "$BATS_TEST_TMPDIR/bin/kubectl" step-ca "$BATS_TEST_TMPDIR/work" \
    server "/step/provisioner-server/password"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/secrets/step-provisioner-server/password" ]
  [ "$output" != "/step/provisioner-server/password" ]
}

@test "ensure_provisioner_password does not overwrite an existing secret and prints the mounted path" {
  mkdir -p "$BATS_TEST_TMPDIR/secrets/step-provisioner-server"
  echo -n "existing-password" >"$BATS_TEST_TMPDIR/secrets/step-provisioner-server/password"
  run ensure_provisioner_password "$BATS_TEST_TMPDIR/bin/kubectl" step-ca "$BATS_TEST_TMPDIR/work" \
    server "/step/provisioner-server/password"
  [ "$status" -eq 0 ]
  [ "$output" = "/step/provisioner-server/password" ]
  run cat "$BATS_TEST_TMPDIR/secrets/step-provisioner-server/password"
  [ "$output" = "existing-password" ]
}

@test "main exits 0 immediately when ca.json already exists, without touching secrets" {
  mkdir -p "$BATS_TEST_TMPDIR/config/config"
  touch "$BATS_TEST_TMPDIR/config/config/ca.json"
  STEP_CONFIG_DIR="$BATS_TEST_TMPDIR/config" run main
  [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/kubectl.log" ]
}

@test "main fails with a clear message when ca.json is missing and the root key is unavailable" {
  mkdir -p "$BATS_TEST_TMPDIR/config"
  mkdir -p "$BATS_TEST_TMPDIR/root-ca"
  echo "cert-only" >"$BATS_TEST_TMPDIR/root-ca/tls.crt" # tls.key/password deliberately absent
  STEP_CONFIG_DIR="$BATS_TEST_TMPDIR/config" STEP_ROOT_CA_DIR="$BATS_TEST_TMPDIR/root-ca" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"restore"*"step-root-ca"* ]]
  [ ! -f "$BATS_TEST_TMPDIR/kubectl.log" ]
}

# Note: main()'s full happy path (past the root-key check) also calls
# fetch_kubectl, which downloads a real kubectl binary from the network -
# so it isn't exercised end-to-end here. ensure_server_ca,
# ensure_provisioner_password, run_step_ca_init, add_idrac_provisioner,
# add_acme_provisioner, and apply_authority_policy are each covered
# individually above against the fake kubectl and real step/jq/openssl.
