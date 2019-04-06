#!/bin/bash -v

curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat <<EOF > /etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
apt-get update
apt-get install -y kubelet kubeadm kubectl kubernetes-cni
curl -sSL https://get.docker.com/ | sh
systemctl start docker

sysctl net.bridge.bridge-nf-call-iptables=1

cat <<EOF > /tmp/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta1
kind: InitConfiguration
bootstrapTokens:
- groups:
  - system:bootstrappers:kubeadm:default-node-token
  token: ${k8stoken}
---
apiVersion: kubeadm.k8s.io/v1beta1
kind: ClusterConfiguration
dns:
  type: kube-dns
networking:
  podSubnet: 172.20.0.0/16
  serviceSubnet: 10.96.0.0/12
EOF
kubeadm init --config=/tmp/kubeadm-config.yaml

echo 'KUBELET_KUBEADM_ARGS=--cgroup-driver=cgroupfs --pod-infra-container-image=k8s.gcr.io/pause:3.1' > /var/lib/kubelet/kubeadm-flags.env
systemctl restart kubelet

export KUBECONFIG=/etc/kubernetes/admin.conf

# Configure kubectl.
mkdir -p /home/ubuntu/.kube
sudo cp -i $KUBECONFIG /home/ubuntu/.kube/config
sudo chown ubuntu: /home/ubuntu/.kube/config

kubectl get cm -n kube-system kube-proxy -oyaml | sed -r '/^\s+resourceVersion:/d' | sed 's/masqueradeAll: false/masqueradeAll: true/' | kubectl replace -f -

kubectl patch -n kube-system deployment kube-dns --patch '{"spec": {"template": {"spec": {"tolerations": [{"key": "CriticalAddonsOnly", "operator": "Exists"}]}}}}'
