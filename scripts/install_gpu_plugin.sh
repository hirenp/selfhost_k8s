#!/bin/bash
set -e

echo "Installing NVIDIA GPU Device Plugin with proper runtime configuration..."

# Clean up any existing installations
echo "Cleaning up any existing NVIDIA device plugin installations..."
kubectl delete daemonset -n kube-system nvidia-device-plugin-daemonset --ignore-not-found=true
kubectl delete daemonset -n kube-system nvidia-device-plugin --ignore-not-found=true
kubectl delete pod -n default nvidia-runtime-test --ignore-not-found=true
kubectl delete pod -n default gpu-test --ignore-not-found=true
kubectl delete runtimeclass nvidia --ignore-not-found=true

# Create NVIDIA RuntimeClass
echo "Creating NVIDIA RuntimeClass..."
cat <<EOF | kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
EOF

# Create a final version of the device plugin
echo "Creating NVIDIA device plugin with proper library configuration..."
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-device-plugin-daemonset
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: nvidia-device-plugin-ds
  template:
    metadata:
      labels:
        name: nvidia-device-plugin-ds
    spec:
      hostNetwork: true
      initContainers:
      - image: busybox:1.35
        name: init-nvidia-lib
        command: ['sh', '-c', 'mkdir -p /nvidia/lib && cp /host/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.* /nvidia/lib/ && cp /host/usr/lib/x86_64-linux-gnu/libnvidia-ptxjitcompiler.so.* /nvidia/lib/ 2>/dev/null || true && ls -la /nvidia/lib/']
        securityContext:
          privileged: true
        volumeMounts:
          - name: host-root
            mountPath: /host
          - name: nvidia-lib-shared
            mountPath: /nvidia/lib
      containers:
      - image: nvcr.io/nvidia/k8s-device-plugin:v0.17.1
        name: nvidia-device-plugin-ctr
        env:
        - name: LD_LIBRARY_PATH
          value: /nvidia/lib
        securityContext:
          privileged: true
        volumeMounts:
          - name: device-plugin
            mountPath: /var/lib/kubelet/device-plugins
          - name: nvidia-lib-shared
            mountPath: /nvidia/lib
      volumes:
        - name: device-plugin
          hostPath:
            path: /var/lib/kubelet/device-plugins
        - name: host-root
          hostPath:
            path: /
        - name: nvidia-lib-shared
          emptyDir: {}
EOF

# Wait for the daemonset to be ready
echo "Waiting for NVIDIA device plugin to be ready..."
kubectl rollout status daemonset/nvidia-device-plugin-daemonset -n kube-system --timeout=60s || true

# Check the logs
echo "Checking logs from device plugin pod..."
sleep 5  # Give it a moment to start up
PLUGIN_POD=$(kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds -o name | head -n 1)
if [ -n "$PLUGIN_POD" ]; then
  kubectl logs -n kube-system $PLUGIN_POD
else
  echo "No NVIDIA device plugin pods found!"
fi

# Verify that GPUs are recognized
echo "Checking if GPUs are recognized by Kubernetes..."
sleep 10  # Give it a moment to register the resources
kubectl get nodes -o=custom-columns=NAME:.metadata.name,GPU:.status.capacity.'nvidia\.com/gpu'

# Create a test pod to verify GPU access
echo "Creating a test pod to verify GPU access..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
  namespace: default
spec:
  runtimeClassName: nvidia
  restartPolicy: OnFailure
  containers:
    - name: cuda-container
      image: nvidia/cuda:12.1.0-base-ubuntu22.04
      command: ["nvidia-smi"]
      resources:
        limits:
          nvidia.com/gpu: 1
EOF

echo "Waiting for the test pod to complete..."
sleep 15
echo "GPU test pod logs:"
kubectl logs gpu-test || echo "Test pod may not be ready yet"

echo "NVIDIA GPU Device Plugin installation complete!"