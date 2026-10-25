#!/bin/bash
#
# step-ca's Deployment initContainer. Deliberately does *not* have access
# to the root/intermediate secrets: initializing the CA (which needs the
# root key) is a separate, deliberately-triggered Job (init/job.yaml),
# not something that happens implicitly every time this pod starts.

if [[ -f /home/step/config/ca.json ]]; then
  echo "CA already initialized" >&2
  exit 0
fi

cat >&2 <<'EOF'
ERROR: step-ca has not been initialized yet (no /home/step/config/ca.json
on the step-data volume).

Run the step-ca-init Job to initialize it, then retry this pod:

  kubectl apply -k base/step-ca/init
  kubectl wait --for=condition=complete -n step-ca job/step-ca-init
EOF
exit 1
