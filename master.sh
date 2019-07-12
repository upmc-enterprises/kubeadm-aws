#!/bin/bash -v

curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat <<EOF > /etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
apt-get update
apt-get install -y kubelet=${k8s_version} kubeadm=${k8s_version} kubectl=${k8s_version} kubernetes-cni docker.io python-pip jq

# Docker sets the policy for the FORWARD chain to DROP, change it back.
iptables -P FORWARD ACCEPT

name=""
while [[ -z "$name" ]]; do
    sleep 1
    name="$(hostname -f)"
done

cat <<EOF > /tmp/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta1
kind: InitConfiguration
bootstrapTokens:
- groups:
  - system:bootstrappers:kubeadm:default-node-token
  token: ${k8stoken}
nodeRegistration:
  name: $name
  kubeletExtraArgs:
    cloud-provider: aws
    network-plugin: kubenet
    non-masquerade-cidr: 0.0.0.0/0
---
apiVersion: kubeadm.k8s.io/v1beta1
kind: ClusterConfiguration
networking:
  podSubnet: ${pod_cidr}
  serviceSubnet: ${service_cidr}
apiServer:
  extraArgs:
    enable-admission-plugins: DefaultStorageClass,NodeRestriction
    cloud-provider: aws
controllerManager:
  extraArgs:
    cloud-provider: aws
    configure-cloud-routes: "true"
    address: 0.0.0.0
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
iptables:
  masqueradeAll: true
EOF
kubeadm init --config=/tmp/kubeadm-config.yaml

export KUBECONFIG=/etc/kubernetes/admin.conf

# Configure kubectl.
mkdir -p /home/ubuntu/.kube
sudo cp -i $KUBECONFIG /home/ubuntu/.kube/config
sudo chown ubuntu: /home/ubuntu/.kube/config

# Create a default storage class, backed by EBS.
cat <<EOF > /tmp/storageclass.yaml
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: ebs
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/aws-ebs
volumeBindingMode: Immediate
reclaimPolicy: Retain
EOF
kubectl apply -f /tmp/storageclass.yaml

# Set up ip-masq-agent.
mkdir -p /tmp/ip-masq-agent-config
cat <<EOF > /tmp/ip-masq-agent-config/config
nonMasqueradeCIDRs:
  - ${pod_cidr}
$(for subnet in ${subnet_cidrs}; do echo "  - $subnet"; done)
EOF
kubectl create -n kube-system configmap ip-masq-agent --from-file=/tmp/ip-masq-agent-config/config
kubectl apply -f https://raw.githubusercontent.com/kubernetes-incubator/ip-masq-agent/master/ip-masq-agent.yaml
kubectl patch -n kube-system daemonset ip-masq-agent --patch '{"spec":{"template":{"spec":{"tolerations":[{"effect":"NoSchedule","key":"node-role.kubernetes.io/master"}]}}}}'

# Start a kube-proxy deployment for Milpa. This will route cluster IP traffic
# from Milpa pods.
cat <<EOF > /tmp/kube-proxy-milpa.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    k8s-app: kube-proxy
  name: kube-proxy
  namespace: kube-system
spec:
  selector:
    matchLabels:
      k8s-app: kube-proxy
  template:
    metadata:
      labels:
        k8s-app: kube-proxy
      annotations:
        kubernetes.io/target-runtime: kiyot
    spec:
      nodeSelector:
        kubernetes.io/role: milpa-worker
      containers:
      - command:
        - /usr/local/bin/kube-proxy
        - --config=/var/lib/kube-proxy/config.conf
        - --hostname-override=$(NODE_NAME)
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              apiVersion: v1
              fieldPath: spec.nodeName
        image: k8s.gcr.io/kube-proxy:v1.15.0
        name: kube-proxy
        resources: {}
        securityContext:
          privileged: true
        volumeMounts:
        - mountPath: /var/lib/kube-proxy
          name: kube-proxy
      dnsPolicy: ClusterFirst
      hostNetwork: true
      priorityClassName: system-node-critical
      restartPolicy: Always
      securityContext: {}
      serviceAccount: kube-proxy
      serviceAccountName: kube-proxy
      terminationGracePeriodSeconds: 30
      volumes:
      - configMap:
          defaultMode: 420
          name: kube-proxy
        name: kube-proxy
EOF
kubectl apply -f /tmp/kube-proxy-milpa.yaml
