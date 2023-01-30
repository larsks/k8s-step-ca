all: step-certificates.yaml

values.yaml.step1:
	step ca init --helm \
		--context house-ca \
		--provisioner-password-file <(echo secret) \
		--password-file <(echo secret) \
		--deployment-type standalone \
		--name "Step CA" \
		--address :9000 \
		--dns localhost \
		--provisioner to-be-removed  > $@ || { rm -f $@; exit 1; }

values.yaml: values.yaml.step1
	yq -y '.inject.certificates.intermediate_ca="INTERMEDIATE CA CERT" | .inject.certificates.root_ca="ROOT CA CERT"' $< | \
	yq -y '.inject.config.files."defaults.json".fingerprint="ROOT CA FINGERPRINT"' | \
	yq -y '.inject.config.files."ca.json".authority.provisioners=[]' | \
	yq -y '.inject.secrets.ca_password="SECRET" | .inject.secrets.provisioner_password="SECRET"' | \
	yq -y '.inject.secrets.x509.intermediate_ca_key="INTERMEDIATE CA KEY" | .inject.secrets.x509.root_ca_key="ROOT CA KEY"' \
	> $@ || { rm -f $@; exit 1; }

step-certificates.yaml: version.txt values.yaml
	helm template -n step-certificates \
		--no-hooks \
		--include-crds \
		--set fullnameOverride=step-certificates \
		-f values.yaml \
		--version=$(shell cat version.txt) \
		smallstep/step-certificates > $@ || { rm -f $@; exit 1; }

clean:
	rm -f step-certificates.yaml
