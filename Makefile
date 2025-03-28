.PHONY: init plan apply destroy setup-kubeconfig monitoring monitoring-dashboard monitoring-prometheus monitoring-all sleep wake status check-hostnames all

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

monitoring-dashboard:
	./scripts/manage_monitoring.sh install-dashboard

monitoring-prometheus:
	./scripts/manage_monitoring.sh install-monitoring

monitoring-all:
	./scripts/manage_monitoring.sh install-all

monitoring:
	./scripts/manage_monitoring.sh access

sleep:
	./scripts/manage_cluster.sh sleep

wake:
	./scripts/manage_cluster.sh wake

status:
	./scripts/manage_cluster.sh status

check-hostnames:
	./scripts/manage_cluster.sh check-hostnames
all: init apply setup-kubeconfig
