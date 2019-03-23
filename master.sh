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

kubeadm init --token=${k8stoken} --pod-network-cidr=172.20.0.0/16

echo 'KUBELET_KUBEADM_ARGS=--cgroup-driver=cgroupfs --pod-infra-container-image=k8s.gcr.io/pause:3.1' > /var/lib/kubelet/kubeadm-flags.env
systemctl restart kubelet

mkdir -p /home/ubuntu/.kube
sudo cp -i /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
sudo chown ubuntu: /home/ubuntu/.kube/config
