setup() {
  load_fixture_ca_json
  source "$BATS_TEST_DIRNAME/../base/step-ca/init-step-ca.sh"
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
