.PHONY: init plan apply destroy destroy-all setup-kubeconfig monitoring monitoring-dashboard monitoring-prometheus monitoring-all install-networking install-ingress install-lb-controller install-gpu-plugin install-cert-manager deploy-ghibli-app enable-tls sleep wakeup status check-hostnames all

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
	
# Individual networking components
install-ingress:
	./scripts/install_ingress_controller.sh

install-lb-controller:
	./scripts/install_load_balancer_controller.sh

# Combined networking target
install-networking: install-ingress install-lb-controller
	@echo "Network components installed successfully"

install-gpu-plugin:
	./scripts/install_gpu_plugin.sh

install-cert-manager:
	./scripts/install_cert_manager.sh

deploy-ghibli-app:
	cd ghibli-app && ./deploy.sh

enable-tls:
	kubectl apply -f ./ghibli-app/k8s/nginx-ingress-class.yaml
	kubectl apply -f ./ghibli-app/k8s/loadbalancer-service.yaml
	kubectl apply -f ./ghibli-app/k8s/ingress.yaml
	@echo "TLS ingress created for ghibli.doandlearn.app"
	@echo "Check certificate status with: kubectl get certificate ghibli-tls-cert"
	@echo ""
	@echo "To access your application, add a CNAME record in Cloudflare DNS:"
	@echo "ghibli.doandlearn.app → $(shell kubectl get svc -n ingress-nginx ingress-nginx-lb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
	@echo ""
	@echo "Run this command on each worker node to register targets:"
	@echo "ssh ubuntu@WORKER_NODE_IP 'sudo /bin/bash -c \"curl -s https://raw.githubusercontent.com/yourusername/selfhost_k8s/main/scripts/register_target_groups.sh | bash\"'"

sleep:
	./scripts/manage_cluster.sh sleep

wakeup:
	./scripts/manage_cluster.sh wakeup

status:
	./scripts/manage_cluster.sh status

check-hostnames:
	./scripts/manage_cluster.sh check-hostnames
all: init apply setup-kubeconfig
