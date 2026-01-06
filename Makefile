.PHONY: setup
setup:
	@git config core.hooksPath .githooks

tfvars := ${SECRETS_DIR}/terraform.tfvars
params_yaml := ${SECRETS_DIR}/params.yaml

define TFVARS
project_root = "$(PROJECT_DIR)"
domain = "$(shell yq e .domain $(params_yaml))"

image_name = "$(shell yq e .image_name $(params_yaml))"

ssh_authorized_keys = $(shell yq --output-format json .ssh.authorized_keys $(params_yaml))
users = "$(shell yq --output-format json .users $(params_yaml) | sed 's/"/\\"/g')"

primary = "$(shell yq e .nameservers.primary $(params_yaml))"
secondaries = $(shell yq --output-format json .nameservers.secondaries $(params_yaml))
resolver_ips = $(shell yq --output-format json .nameservers.resolver_ips $(params_yaml))
auth_ips = $(shell yq --output-format json .nameservers.auth_ips $(params_yaml))

cpus = $(shell yq e .node.cpus $(params_yaml))
memory = $(shell yq e .node.memory $(params_yaml))
disk_size = $(shell yq e .node.disk_size $(params_yaml))

nutanix_username = "$(shell yq e .nutanix.username $(params_yaml))"
nutanix_password = "$(shell sops --decrypt --extract '["nutanix"]["password"]' $(params_yaml))"
nutanix_prism_central = "$(shell yq e .nutanix.prism_central $(params_yaml))"
nutanix_cluster_name = "$(shell yq e .nutanix.cluster $(params_yaml))"
nutanix_storage_container = $(shell yq e '.nutanix.storage_container // "null"' $(params_yaml))

infra_subnet = {
  vlan_id = $(shell yq e .subnets.infra.vlan_id $(params_yaml))
  cidr = "$(shell yq e .subnets.infra.cidr $(params_yaml))"
  gateway = "$(shell yq e .subnets.infra.gateway $(params_yaml))"
  pool_start = "$(shell yq e .subnets.infra.pool_start $(params_yaml))"
  pool_end = "$(shell yq e .subnets.infra.pool_end $(params_yaml))"
}

management_subnet = {
  vlan_id = $(shell yq e .subnets.management.vlan_id $(params_yaml))
  cidr = "$(shell yq e .subnets.management.cidr $(params_yaml))"
  gateway = "$(shell yq e .subnets.management.gateway $(params_yaml))"
  pool_start = "$(shell yq e .subnets.management.pool_start $(params_yaml))"
  pool_end = "$(shell yq e .subnets.management.pool_end $(params_yaml))"
}

octodns_allowed_ranges = $(shell yq --output-format json .octodns.allowed_ranges $(params_yaml))

tls_cert = <<-EOF
$(shell sops --decrypt --extract '["tls"]["cert"]' $(params_yaml))
EOF

tls_key = <<-EOF
$(shell sops --decrypt --extract '["tls"]["key"]' $(params_yaml))
EOF

tls_ca = <<-EOF
$(shell sops --decrypt --extract '["tls"]["ca"]' $(params_yaml))
EOF

tailscale_auth_key = "$(shell sops --decrypt --extract '["tailscale"]["auth_key"]' $(params_yaml) 2>/dev/null || echo '')"
endef

.PHONY: tfvars
tfvars: $(tfvars)

export TFVARS
$(tfvars): $(params_yaml)
	@echo "$$TFVARS" > $@

.PHONY: init
init: $(tfvars)
	@(cd $(DEPLOY_DIR)/terraform && terraform init)

.PHONY: servers
servers: $(tfvars)
	@(cd ${DEPLOY_DIR}/terraform && terraform apply -var-file $(tfvars) --auto-approve)

.PHONY: plan
plan: $(tfvars)
	@(cd ${DEPLOY_DIR}/terraform && terraform plan -var-file $(tfvars))

.PHONY: destroy
destroy: $(tfvars)
	@(cd ${DEPLOY_DIR}/terraform && terraform destroy -var-file $(tfvars) --auto-approve)

.PHONY: clean
clean:
	@rm -f $(tfvars)

.PHONY: encrypt
encrypt:
	@sops --encrypt --in-place $(params_yaml)

.PHONY: decrypt
decrypt:
	@sops --decrypt --in-place $(params_yaml)

.PHONY: show-tsig
show-tsig:
	@(cd ${DEPLOY_DIR}/terraform && terraform output -raw tsig_secret)
