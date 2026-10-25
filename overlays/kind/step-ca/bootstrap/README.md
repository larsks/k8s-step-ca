# step-ca bootstrap (kind)

One-time (or disaster-recovery) provisioning: a Job generates the
root/intermediate CA material and passwords entirely in-cluster (or
restores previously-backed-up material - see below), writes them into
scratch Secrets, and three PushSecrets copy those into `step-ca-secrets`,
the kind-local stand-in for an external vault. The main
`overlays/kind/step-ca` overlay only ever reads from `step-ca-secrets` via
`ExternalSecret`; it has no idea how the data got there.

```
kubectl apply -k .
kubectl wait --for=condition=complete --timeout=120s -n step-ca job/step-ca-bootstrap
# wait for all three PushSecrets to report Synced, then:
kubectl delete -k .
```

`kubectl delete -k .` removes the scratch secrets and the PushSecrets
themselves - `step-ca-secrets` now holds the only copy, which is the point.

## Restoring from a backup

If you're rebuilding the CA after losing the cluster (or just want to
re-supply previously-generated material rather than mint a new CA), create
a `step-ca-restore` Secret in the `step-ca` namespace *before* running the
Job, with these keys (raw file contents, not pre-base64-encoded - `kubectl`
handles that):

```
kubectl -n step-ca create secret generic step-ca-restore \
  --from-file=root_ca.crt=... \
  --from-file=root_ca.key=... \
  --from-file=root_password=... \
  --from-file=intermediate_ca.crt=... \
  --from-file=intermediate_ca.key=... \
  --from-file=step_password=...
```

The Job checks for this Secret first and uses it as-is instead of
generating fresh material. Delete it along with everything else once the
push has succeeded.
