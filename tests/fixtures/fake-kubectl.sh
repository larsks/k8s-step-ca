#!/usr/bin/env bash
#
# Stub `kubectl` for bats tests exercising ensure_server_ca/
# ensure_provisioner_password without touching a real cluster.
#
# Secrets are backed by flat files under $FAKE_KUBECTL_SECRETS_DIR/<name>/<key>,
# each holding that field's raw (decoded) bytes.
#
# - `get secret <name> -o go-template={{index .data "<key>"}}` re-encodes
#   that raw content as base64 before printing - matching real kubectl,
#   whose `.data` fields are already base64 in the Secret API object - or
#   exits non-zero if the secret or field file is absent.
# - `apply -f -` reads a Secret manifest from stdin, in exactly the shape
#   this script's own init-step-ca.sh produces (a top-level `metadata.name`
#   and a top-level `data:` map of `key: base64value` pairs), and
#   base64-decodes each value into $FAKE_KUBECTL_SECRETS_DIR/<name>/<key>.
#
# Every invocation's arguments are appended to $FAKE_KUBECTL_LOG, if set.
set -euo pipefail

: "${FAKE_KUBECTL_SECRETS_DIR:?FAKE_KUBECTL_SECRETS_DIR must be set}"

if [[ -n "${FAKE_KUBECTL_LOG:-}" ]]; then
  printf '%s\n' "$*" >>"$FAKE_KUBECTL_LOG"
fi

# Consume (and discard) a leading "-n <namespace>"; this fixture doesn't
# namespace its on-disk secret store, since tests only ever use one.
if [[ "${1:-}" == "-n" ]]; then
  shift 2
fi

case "${1:-}" in
get)
  # get secret <name> -o go-template={{index .data "<key>"}}
  secret_name="$3"
  template="$5"
  field="$(printf '%s' "$template" | sed -n 's/.*index \.data "\([^"]*\)".*/\1/p')"
  secret_file="$FAKE_KUBECTL_SECRETS_DIR/$secret_name/$field"
  [[ -n "$field" && -f "$secret_file" ]] || exit 1
  base64 -w0 <"$secret_file"
  ;;
apply)
  # apply -f -
  name=""
  in_data=0
  declare -A fields=()
  while IFS= read -r line; do
    if [[ -z "$name" && "$line" =~ ^[[:space:]]{2}name:[[:space:]]*(.+)$ ]]; then
      name="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "$line" == "data:" ]]; then
      in_data=1
      continue
    fi
    if [[ $in_data -eq 1 ]]; then
      if [[ "$line" =~ ^[[:space:]]{2}([A-Za-z0-9._-]+):[[:space:]]*(.*)$ ]]; then
        fields["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
        continue
      fi
      in_data=0
    fi
  done

  [[ -n "$name" ]] || {
    echo "fake-kubectl: could not parse metadata.name from manifest" >&2
    exit 1
  }

  mkdir -p "$FAKE_KUBECTL_SECRETS_DIR/$name"
  for key in "${!fields[@]}"; do
    printf '%s' "${fields[$key]}" | base64 -d >"$FAKE_KUBECTL_SECRETS_DIR/$name/$key"
  done
  ;;
*)
  echo "fake-kubectl: unsupported invocation: $*" >&2
  exit 1
  ;;
esac
