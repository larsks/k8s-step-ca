{
    "subject": {{ toJson .Subject }},
    "sans": {{ toJson .SANs }},
    {{- if typeIs "*rsa.PublicKey" .Insecure.CR.PublicKey }}
    "keyUsage": ["keyEncipherment", "digitalSignature"],
    {{- else }}
    {{ fail "key type must be RSA: iDRAC devices do not support EC/Ed25519 certificates, sign the CSR with an RSA key" }}
    {{- end }}
    "extKeyUsage": ["serverAuth", "clientAuth"]
}
