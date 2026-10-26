{{/*
    Shared by every provisioner that uses it (see attach_x509_template and
    build_x509_template_data in init-step-ca.sh). A SAN is kept only when
    it matches one of AllowDNSSuffixes/AllowIPPrefixes, discarding
    anything else the device's CSR requested - notably the bare,
    unqualified hostnames some BMCs always add, which step-ca's
    authority-level policy engine can never admit (no wildcard matches a
    single DNS label with no domain suffix). The key type is restricted to
    AllowedKeyTypes when that list is non-empty (e.g. idrac gets ["RSA"],
    since iDRAC devices don't support EC/Ed25519 certificates); an empty
    list means no restriction. All three are injected per-provisioner as
    --x509-template-data, so one template file serves every provisioner.
*/}}
{
    "subject": {{ toJson .Subject }},
    "sans": [
        {{- $items := list -}}
        {{- range .SANs }}
            {{- $san := . }}
            {{- $keep := false }}
            {{- if eq $san.Type "ip" }}
                {{- range $.AllowIPPrefixes }}
                    {{- if hasPrefix . $san.Value }}{{- $keep = true }}{{- end }}
                {{- end }}
            {{- else if eq $san.Type "dns" }}
                {{- range $.AllowDNSSuffixes }}
                    {{- if hasSuffix . $san.Value }}{{- $keep = true }}{{- end }}
                {{- end }}
            {{- end }}
            {{- if $keep }}{{- $items = append $items $san }}{{- end }}
        {{- end }}
        {{- range $i, $e := $items }}{{ if $i }},{{ end }}{{ toJson $e }}{{ end }}
    ],
    {{- $keyType := "" }}
    {{- if typeIs "*rsa.PublicKey" .Insecure.CR.PublicKey }}
        {{- $keyType = "RSA" }}
    {{- else if typeIs "*ecdsa.PublicKey" .Insecure.CR.PublicKey }}
        {{- $keyType = "ECDSA" }}
    {{- else if typeIs "ed25519.PublicKey" .Insecure.CR.PublicKey }}
        {{- $keyType = "Ed25519" }}
    {{- end }}
    {{- if $.AllowedKeyTypes }}
        {{- $keyTypeOk := false }}
        {{- range $.AllowedKeyTypes }}
            {{- if eq . $keyType }}{{- $keyTypeOk = true }}{{- end }}
        {{- end }}
        {{- if not $keyTypeOk }}
            {{ fail (printf "key type must be one of %v (got %s)" $.AllowedKeyTypes $keyType) }}
        {{- end }}
    {{- end }}
    "keyUsage": ["keyEncipherment", "digitalSignature"],
    "extKeyUsage": ["serverAuth", "clientAuth"]
}
