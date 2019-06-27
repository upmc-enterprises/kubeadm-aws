#!/bin/bash -v

curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat <<EOF > /etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
apt-get update
apt-get install -y kubelet kubeadm kubectl kubernetes-cni python python-pip jq docker.io

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
#  criSocket: unix:///opt/milpa/run/kiyot.sock
  kubeletExtraArgs:
    cloud-provider: aws
    max-pods: "1000"
    node-labels: kubernetes.io/role=milpa-worker
EOF

curl -L ${milpa_installer_url} > milpa-installer-latest
chmod 755 milpa-installer-latest
./milpa-installer-latest

pip install yq
yq -y ".clusterName=\"${cluster_name}\" | .cloud.aws.accessKeyID=\"${aws_access_key_id}\" | .cloud.aws.secretAccessKey=\"${aws_secret_access_key}\" | .cloud.aws.vpcID=\"\" | .nodes.itzo.url=\"${itzo_url}\" | .nodes.itzo.version=\"${itzo_version}\" | .nodes.extraCIDRs=[\"${pod_cidr}\"] | .license.key=\"${license_key}\" | .license.id=\"${license_id}\" | .license.username=\"${license_username}\" | .license.password=\"${license_password}\"" /opt/milpa/etc/server.yml > /opt/milpa/etc/server.yml.new && mv /opt/milpa/etc/server.yml.new /opt/milpa/etc/server.yml
sed -i 's#--milpa-endpoint 127.0.0.1:54555$#--milpa-endpoint 127.0.0.1:54555 --service-cluster-ip-range ${service_cidr} --kubeconfig /etc/kubernetes/kubelet.conf#' /etc/systemd/system/kiyot.service
sed -i 's#--config /opt/milpa/etc/server.yml$#--config /opt/milpa/etc/server.yml --delete-cluster-lock-file#' /etc/systemd/system/milpa.service
mkdir -p /etc/systemd/system/kubelet.service.d/
echo -e "[Service]\nStartLimitInterval=0\nStartLimitIntervalSec=0\nRestart=always\nRestartSec=5" > /etc/systemd/system/kubelet.service.d/override.conf

for i in {1..50}; do kubeadm join --config=/tmp/kubeadm-config.yaml && break || sleep 15; done

# TODO: have kiyot retry creating k8s client and connect to the API server, and
# have kubeadm configure the CRI. Then we can override all the extra parameters
# via kubeletExtraArgs, and don't need to update kubeadm-flags.env here.
echo "KUBELET_KUBEADM_ARGS=--cloud-provider=aws --hostname-override=$(hostname -f) --cgroup-driver=cgroupfs --pod-infra-container-image=k8s.gcr.io/pause:3.1 --container-runtime=remote --container-runtime-endpoint=unix:///opt/milpa/run/kiyot.sock --max-pods=1000" > /var/lib/kubelet/kubeadm-flags.env

systemctl daemon-reload
systemctl restart milpa
systemctl restart kiyot
systemctl restart kubelet

docker ps -aq --no-trunc | xargs docker stop
docker ps -aq --no-trunc | xargs docker rm
