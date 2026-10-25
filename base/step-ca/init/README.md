# step-ca init

Runs `step ca init` using the root/intermediate secrets, producing
`/home/step/config/ca.json` on the `step-data` PVC. This is the *only*
place the root key is ever mounted - the main Deployment's initContainer
just checks that `ca.json` already exists and refuses to start otherwise
(see `../check-ca-initialized.sh`).

Run this once, after `step-password`, `step-root-certificate`, and
`step-intermediate-certificate` exist (via the `ExternalSecret`s in the
overlay) but before - or instead of - the main Deployment's pod is
running:

```
kubectl scale -n step-ca deploy/step-ca --replicas=0   # if it's already running/crash-looping
kubectl apply -k .
kubectl wait --for=condition=complete --timeout=120s -n step-ca job/step-ca-init
kubectl scale -n step-ca deploy/step-ca --replicas=1
kubectl delete -k .
```

`step-data` is a ReadWriteOnce PVC, so this Job and the Deployment's pod
shouldn't run at the same time - scaling the Deployment to 0 first avoids
both trying to mount it together. `step-ca-init`'s own script
(`../init-step-ca.sh`) is idempotent (skips `step ca init` if `ca.json`
already exists), so re-running this is always safe.
