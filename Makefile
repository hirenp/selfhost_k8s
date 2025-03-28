.PHONY: init plan apply destroy setup-kubeconfig install-dashboard install-monitoring dashboard sleep wake status check-hostnames all

init:
	cd terraform && terraform init

plan:
	cd terraform && terraform plan

apply:
	cd terraform && terraform apply

destroy:
	cd terraform && terraform destroy

setup-kubeconfig:
	./scripts/setup_kubeconfig.sh

install-dashboard:
	./scripts/install_dashboard.sh

install-monitoring:
	./scripts/install_monitoring.sh

dashboard:
	./scripts/access_dashboard.sh

sleep:
	./scripts/manage_cluster.sh sleep

wake:
	./scripts/manage_cluster.sh wake

status:
	./scripts/manage_cluster.sh status

check-hostnames:
	./scripts/manage_cluster.sh check-hostnames
all: init apply setup-kubeconfig
