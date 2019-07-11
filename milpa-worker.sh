#!/bin/bash -v

curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat <<EOF > /etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
apt-get update
apt-get install -y kubelet=${k8s_version} kubeadm=${k8s_version} kubectl=${k8s_version} kubernetes-cni containerd python-pip jq

# Configure containerd. This assumes kubenet is used for networking.
modprobe br_netfilter
sysctl net.bridge.bridge-nf-call-iptables=1; echo "net.bridge.bridge-nf-call-iptables=1" >> /etc/sysctl.conf
sysctl net.ipv4.ip_forward=1; echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
mkdir -p /etc/cni/net.d
mkdir -p /etc/containerd
cat <<EOF > /etc/containerd/config.toml
[plugins.cri]
  [plugins.cri.cni]
    conf_template = "/etc/containerd/cni-template.json"
EOF
cat <<EOF > /etc/containerd/cni-template.json
{
  "cniVersion": "0.3.1",
  "name": "containerd-net",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cni0",
      "isGateway": true,
      "ipMasq": true,
      "promiscMode": true,
      "ipam": {
        "type": "host-local",
        "subnet": "{{.PodCIDR}}",
        "routes": [
          { "dst": "0.0.0.0/0" }
        ]
      }
    },
    {
      "type": "portmap",
      "capabilities": {"portMappings": true}
    }
  ]
}
EOF
systemctl restart containerd

# Install criproxy.
curl -L https://milpa-builds.s3.amazonaws.com/criproxy > /usr/local/bin/criproxy; chmod 755 /usr/local/bin/criproxy
cat <<EOF > /etc/systemd/system/criproxy.service
[Unit]
Description=CRI Proxy
Wants=containerd.service

[Service]
ExecStart=/usr/local/bin/criproxy -v 3 -logtostderr -connect /run/containerd/containerd.sock,kiyot:/opt/milpa/run/kiyot.sock -listen /run/criproxy.sock
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=kubelet.service
EOF
systemctl daemon-reload
systemctl restart criproxy

# Configure kubelet.
name=""
while [[ -z "$name" ]]; do
    sleep 1
    name="$(hostname -f)"
done

cat <<EOF > /tmp/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta1
kind: JoinConfiguration
discovery:
  bootstrapToken:
    token: ${k8stoken}
    unsafeSkipCAVerification: true
    apiServerEndpoint: ${masterIP}:6443
nodeRegistration:
  name: $name
  criSocket: unix:///run/criproxy.sock
  kubeletExtraArgs:
    cloud-provider: aws
    network-plugin: kubenet
    non-masquerade-cidr: 0.0.0.0/0
    max-pods: "1000"
    node-labels: kubernetes.io/role=milpa-worker
EOF

# Install milpa and kiyot.
curl -L ${milpa_installer_url} > milpa-installer-latest
chmod 755 milpa-installer-latest
./milpa-installer-latest

# Configure milpa and kiyot.
pip install yq
yq -y ".clusterName=\"${cluster_name}\" | .cloud.aws.accessKeyID=\"${aws_access_key_id}\" | .cloud.aws.secretAccessKey=\"${aws_secret_access_key}\" | .cloud.aws.vpcID=\"\" | .nodes.itzo.url=\"${itzo_url}\" | .nodes.itzo.version=\"${itzo_version}\" | .nodes.extraCIDRs=[\"${pod_cidr}\"] | .license.key=\"${license_key}\" | .license.id=\"${license_id}\" | .license.username=\"${license_username}\" | .license.password=\"${license_password}\"" /opt/milpa/etc/server.yml > /opt/milpa/etc/server.yml.new && mv /opt/milpa/etc/server.yml.new /opt/milpa/etc/server.yml
sed -i 's#--milpa-endpoint 127.0.0.1:54555$#--milpa-endpoint 127.0.0.1:54555 --service-cluster-ip-range ${service_cidr} --kubeconfig /etc/kubernetes/kubelet.conf#' /etc/systemd/system/kiyot.service
sed -i 's#--config /opt/milpa/etc/server.yml$#--config /opt/milpa/etc/server.yml --delete-cluster-lock-file#' /etc/systemd/system/milpa.service

# Ensure systemd will keep restarting kubelet.
mkdir -p /etc/systemd/system/kubelet.service.d/
echo -e "[Service]\nStartLimitInterval=0\nStartLimitIntervalSec=0\nRestart=always\nRestartSec=5" > /etc/systemd/system/kubelet.service.d/override.conf

for i in {1..50}; do kubeadm join --config=/tmp/kubeadm-config.yaml && break || sleep 15; done

systemctl daemon-reload
systemctl restart milpa
systemctl restart kiyot
systemctl restart kubelet
