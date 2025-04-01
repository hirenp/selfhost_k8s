.PHONY: init plan apply destroy destroy-all setup-kubeconfig monitoring monitoring-dashboard monitoring-prometheus monitoring-all install-ingress install-gpu-plugin sleep wakeup status check-hostnames all

init:
	cd terraform && terraform init

plan:
	cd terraform && terraform plan

apply:
	cd terraform && terraform apply

destroy:
	cd terraform && terraform destroy

destroy-all:
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
	
install-ingress:
	./scripts/install_ingress_controller.sh

install-gpu-plugin:
	./scripts/install_gpu_plugin.sh

sleep:
	./scripts/manage_cluster.sh sleep

wakeup:
	./scripts/manage_cluster.sh wakeup

status:
	./scripts/manage_cluster.sh status

check-hostnames:
	./scripts/manage_cluster.sh check-hostnames
all: init apply setup-kubeconfig
