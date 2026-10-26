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
