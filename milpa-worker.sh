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
yq -y '.clusterName="${cluster_name}" | .cloud.aws.accessKeyID="${aws_access_key_id}" | .cloud.aws.secretAccessKey="${aws_secret_access_key}" | .cloud.aws.vpcID="" | .nodes.nametag="${cluster_name}" | .nodes.itzo.url="${itzo_url}" | .nodes.itzo.version="${itzo_version}" | .nodes.extraCIDRs=["${pod_cidr}"] | .nodes.defaultInstanceType="${default_instance_type}" | .nodes.defaultVolumeSize="${default_volume_size}" | .nodes.bootImageTags=${boot_image_tags} | .license.key="${license_key}" | .license.id="${license_id}" | .license.username="${license_username}" | .license.password="${license_password}"' /opt/milpa/etc/server.yml > /opt/milpa/etc/server.yml.new && mv /opt/milpa/etc/server.yml.new /opt/milpa/etc/server.yml
sed -i 's#--milpa-endpoint 127.0.0.1:54555$#--milpa-endpoint 127.0.0.1:54555 --service-cluster-ip-range ${service_cidr} --kubeconfig /etc/kubernetes/kubelet.conf#' /etc/systemd/system/kiyot.service
sed -i '/mount/d' /etc/systemd/system/kiyot.service
sed -i 's#--config /opt/milpa/etc/server.yml$#--config /opt/milpa/etc/server.yml --delete-cluster-lock-file#' /etc/systemd/system/milpa.service

# Ensure systemd will keep restarting kubelet.
mkdir -p /etc/systemd/system/kubelet.service.d/
echo -e "[Service]\nStartLimitInterval=0\nStartLimitIntervalSec=0\nRestart=always\nRestartSec=5" > /etc/systemd/system/kubelet.service.d/override.conf

# Override number of CPUs and memory cadvisor reports.
infodir=/run/kiyot/proc
mkdir -p $infodir; rm -f $infodir/{cpu,mem}info
for i in $(seq 0 1023); do
    cat << EOF >> $infodir/cpuinfo
processor	: $i
vendor_id	: GenuineIntel
cpu family	: 6
model		: 63
model name	: Intel(R) Xeon(R) CPU E5-2676 v3 @ 2.40GHz
stepping	: 2
microcode	: 0x3c
cpu MHz		: 2400.068
cache size	: 30720 KB
physical id	: 0
siblings	: 1
core id		: 0
cpu cores	: 1
apicid		: 0
initial apicid	: 0
fpu		: yes
fpu_exception	: yes
cpuid level	: 13
wp		: yes
flags		: fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush mmx fxsr sse sse2 ht syscall nx rdtscp lm constant_tsc rep_good nopl xtopology eagerfpu pni pclmulqdq ssse3 fma cx16 pcid sse4_1 sse4_2 x2apic movbe popcnt tsc_deadline_timer aes xsave avx f16c rdrand hypervisor lahf_lm abm invpcid_single retpoline kaiser fsgsbase bmi1 avx2 smep bmi2 erms invpcid xsaveopt
bugs		: cpu_meltdown spectre_v1 spectre_v2
bogomips	: 4800.13
clflush size	: 64
cache_alignment	: 64
address sizes	: 46 bits physical, 48 bits virtual
power management:
EOF
done

mem=$((4096*1024*1024))
cat << EOF > $infodir/meminfo
$(printf "MemTotal:%15d kB" $mem)
$(printf "MemFree:%16d kB" $mem)
$(printf "MemAvailable:%11d kB" $mem)
Buffers:          130288 kB
Cached:          1551876 kB
SwapCached:            0 kB
Active:          1059664 kB
Inactive:         785988 kB
Active(anon):     164180 kB
Inactive(anon):      244 kB
Active(file):     895484 kB
Inactive(file):   785744 kB
Unevictable:           0 kB
Mlocked:               0 kB
SwapTotal:             0 kB
SwapFree:              0 kB
Dirty:              1236 kB
Writeback:             0 kB
AnonPages:        163432 kB
Mapped:           174164 kB
Shmem:               992 kB
Slab:             101304 kB
SReclaimable:      80056 kB
SUnreclaim:        21248 kB
KernelStack:        3536 kB
PageTables:         4300 kB
NFS_Unstable:          0 kB
Bounce:                0 kB
WritebackTmp:          0 kB
CommitLimit:     1025472 kB
Committed_AS:    1399960 kB
VmallocTotal:   34359738367 kB
VmallocUsed:           0 kB
VmallocChunk:          0 kB
HardwareCorrupted:     0 kB
AnonHugePages:         0 kB
HugePages_Total:       0
HugePages_Free:        0
HugePages_Rsvd:        0
HugePages_Surp:        0
Hugepagesize:       2048 kB
DirectMap4k:       57344 kB
DirectMap2M:     2039808 kB
EOF

for info in {cpu,mem}info; do
    /bin/mount | /bin/grep "\\W/proc/$info\\W" || /bin/mount --bind $infodir/$info /proc/$info
done

# Join cluster.
for i in {1..50}; do kubeadm join --config=/tmp/kubeadm-config.yaml && break || sleep 15; done

systemctl daemon-reload
systemctl restart milpa
systemctl restart kiyot
systemctl restart kubelet
