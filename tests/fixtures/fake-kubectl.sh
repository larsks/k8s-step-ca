#!/usr/bin/env bash
#
# Stub `kubectl` for bats tests exercising ensure_server_ca/
# ensure_provisioner_password without touching a real cluster.
#
# Secrets are backed by flat files under $FAKE_KUBECTL_SECRETS_DIR/<name>/<key>,
# each holding that field's raw (decoded) bytes. A secret exists if its
# directory exists, whether or not it has any field files.
#
# - `get secret <name> [--ignore-not-found] -o go-template=<template>`
#   mirrors real kubectl's behavior for the two template shapes below,
#   re-encoding a field's raw content as base64 before printing (real
#   kubectl's `.data` fields are already base64 in the Secret API object):
#     - `{{index .data "<key>"}}` prints `<no value>` and exits 0 when the
#       field is missing, exactly as real kubectl does.
#     - `{{with .data}}{{with index . "<key>"}}{{.}}{{end}}{{end}}` prints
#       nothing and exits 0 when the field is missing or empty.
#   A missing secret prints a NotFound error and exits 1, unless
#   --ignore-not-found is given, in which case it prints nothing and exits
#   0. If $FAKE_KUBECTL_GET_FAILS is set, every `get` fails as if the API
#   were unreachable.
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
  # get secret <name> [--ignore-not-found] -o go-template=<template>
  secret_name="$3"
  shift 3
  ignore_not_found=0
  template=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --ignore-not-found) ignore_not_found=1 ;;
    -o)
      shift
      template="${1#go-template=}"
      ;;
    -o=go-template=* | --output=go-template=*) template="${1#*go-template=}" ;;
    *)
      echo "fake-kubectl: unsupported get argument: $1" >&2
      exit 1
      ;;
    esac
    shift
  done

  if [[ -n "${FAKE_KUBECTL_GET_FAILS:-}" ]]; then
    echo "Unable to connect to the server: dial tcp: connection refused" >&2
    exit 1
  fi

  secret_dir="$FAKE_KUBECTL_SECRETS_DIR/$secret_name"
  if [[ ! -d "$secret_dir" ]]; then
    [[ $ignore_not_found -eq 1 ]] && exit 0
    echo "Error from server (NotFound): secrets \"$secret_name\" not found" >&2
    exit 1
  fi

  if [[ "$template" =~ ^\{\{with\ \.data\}\}\{\{with\ index\ \.\ \"([^\"]+)\"\}\}\{\{\.\}\}\{\{end\}\}\{\{end\}\}$ ]]; then
    field="${BASH_REMATCH[1]}"
    if [[ -s "$secret_dir/$field" ]]; then
      base64 -w0 <"$secret_dir/$field"
    fi
  elif [[ "$template" =~ ^\{\{index\ \.data\ \"([^\"]+)\"\}\}$ ]]; then
    field="${BASH_REMATCH[1]}"
    if [[ -f "$secret_dir/$field" ]]; then
      base64 -w0 <"$secret_dir/$field"
    else
      printf '<no value>'
    fi
  else
    echo "fake-kubectl: unsupported template: $template" >&2
    exit 1
  fi
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
  echo "secret/$name configured"
  ;;
*)
  echo "fake-kubectl: unsupported invocation: $*" >&2
  exit 1
  ;;
esac
