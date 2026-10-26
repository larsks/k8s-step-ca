# Initializing Step CA

## Certificate authorities

These secrets must exist before step-ca can start for the first time:

- `step-root-ca` with the following keys:

  Because one of our intermediate CAs will be using iDRAC 8 certificates, this
  MUST be an RSA certificate. It is an error if it contains an ECDSA
  certifiate.

  - `tls.crt` -- root ca certificate
  - `tls.key` -- root ca key
  - `password` -- root ca key password

These secrets *may* exist; if they do not, the required values will be generated
and stored back to the same secret:

- `step-server-ca`

  This is an intermediate CA for general use server certificates.

  - `tls.crt` -- server ca certificate
  - `tls.key` -- server ca key
  - `password` -- server ca key password

All of the above are ordinary Kubernetes `Secret` objects; how an operator
populates or backs them up externally (importing existing material with
their own `ExternalSecret`, exporting generated material with their own
`PushSecret`, or just `kubectl create secret` by hand) is their choice and
out of scope here. Nothing in this repository assumes or requires an
external secret store.

## Initialization process

`step ca init` runs in an initContainer on the step-ca pod itself, not a
separate Job. It is idempotent: it is skipped only if a completion marker
file exists on the `step-data` volume, written as the last step after
`step ca init` and every provisioner/policy configuration step has
succeeded. If a previous run failed partway through, the marker is absent,
so the initContainer wipes any partial state and runs the whole sequence
again from scratch. This makes it safe to run on every pod start, including
rollouts, reschedules, and node evictions, without ever leaving step-ca
serving with incomplete provisioners or policy.

Running it as an initContainer rather than a separate Job avoids needing to
coordinate access to the `step-data` PVC: since `step-data` is
ReadWriteOnce, a separate init Job would require scaling the Deployment to
0 first so the Job and the running pod never mount it at once. An
initContainer shares the pod (and its PVC mount) with the main container,
so no such choreography is needed.

The same initContainer also generates any of `step-server-ca` or
`step-provisioner-<name>` that don't already exist, writing them back as
Secrets before using them, so no separate bootstrap step is needed. This
means the step-ca Deployment's ServiceAccount needs standing RBAC to
get/create/update Secrets in its own namespace -- a broader, longer-lived
grant than if generation were done by a separate one-shot Job, accepted
here in exchange for not needing a second workload.

## Root CA key lifecycle

The root CA key and its password are only ever needed for two things:

- Signing the intermediate CA during the first `step ca init` (see
  Initialization process, above).
- Regenerating `ca.json` if it is ever lost (e.g. the `step-data` PVC is
  lost or recreated).

Because the initContainer's idempotency check happens before the root key
or password is ever read, neither needs to remain available once the
completion marker exists. Once the Deployment is confirmed healthy, an
operator should replace the `step-root-ca` secret with a cert-only version
(`tls.crt` only; drop `tls.key` and `password`), so the root key no longer
exists in-cluster during normal operation.

The full `step-root-ca` secret (with key and password) only needs to be
restored temporarily for disaster recovery, i.e. if the completion marker
(or the whole `step-data` volume) is lost and `step ca init` needs to run
again.

## Provisioners

- `server` -- JWT provisioner for general purpose server use. This is the
  provisioner created by `step ca init` itself; since remote
  administration is disabled, there is no separate "admin" role for it to
  fill, so it is created directly as `server` rather than as `admin` with
  a second `server` provisioner added afterward.

- `idrac` -- JWT provisioner that can only issue RSA certificates

- `acme` -- this is an acme provisioner

The certificate lifetime for all provisioners should default to 90 days. All
provisioners should be limited to issuing certificates for DNS sans matching
*.massopen.cloud (where `*` matches multiple levels, so foo.bar.massopen.cloud
is valid) and IP sans for the 10.0.0.0/8 network.

For the JWT passwords, if a secret `step-provisioner-<name>` exists we will use
that password, otherwise we will generate a random password and store it to
secret `step-provisioner-<name>`.

Remote administration (`step ca init --remote-management`) is disabled.
`step ca init` itself only configures a single provisioner, so the
remaining provisioners, their x509 templates (e.g. the RSA-only
restriction for `idrac`), and the authority-level SAN policy are all
assembled directly into `ca.json` by the initContainer, rather than added
afterward over the remote admin API. This also means there is no admin
subject or remote-administration credential to allow-list against the
DNS SAN policy, and no need to wait for the CA to become healthy before
configuring provisioners -- everything is in place before `step-ca`
starts for the first time.

Because there is no remote admin API, changing provisioners or policy
later (e.g. adding a new provisioner, or adjusting the allowed SAN
patterns) means updating `ca.json` and reloading step-ca (`SIGHUP`)
rather than running a `step ca provisioner`/`step ca policy` command
against a running server.
