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

cat <<EOF > /tmp/kiyot-device-plugin.yaml
apiVersion: extensions/v1beta1
kind: DaemonSet
metadata:
  name: kiyot-device-plugin
  namespace: kube-system
spec:
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        name: kiyot-device-plugin
    spec:
      priorityClassName: "system-node-critical"
      nodeSelector:
        kubernetes.io/role: milpa-worker
      containers:
      - image: elotl/kiyot-device-plugin:latest
        name: kiyot-device-plugin
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        volumeMounts:
          - name: device-plugin
            mountPath: /var/lib/kubelet/device-plugins
      volumes:
        - name: device-plugin
          hostPath:
            path: /var/lib/kubelet/device-plugins
EOF
kubectl apply -f /tmp/kiyot-device-plugin.yaml

cat <<EOF > /tmp/kiyot-ds.yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: milpa-config
  namespace: kube-system
data:
  SERVICE_CIDR: "${service_cidr}"
  server.yml: |
    apiVersion: v1
    cloud:
      aws:
        region: "${aws_region}"
        accessKeyID: "${aws_access_key_id}"
        secretAccessKey: "${aws_secret_access_key}"
        imageOwnerID: 689494258501
    etcd:
      client:
        endpoints: []
        certFile: ""
        keyFile: ""
        caFile: ""
      internal:
        dataDir: /shared/milpa/data
    nodes:
      firewallMode: OpenToVPC
      defaultInstanceType: "${default_instance_type}"
      defaultVolumeSize: "${default_volume_size}"
      bootImageTags: ${boot_image_tags}
      nametag: "${node_nametag}"
      extraCIDRs:
      - "${pod_cidr}"
      itzo:
        url: "${itzo_url}"
        version: "${itzo_version}"
    license:
      key: "${license_key}"
      id: "${license_id}"
      username: "${license_username}"
      password: "${license_password}"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kiyot
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kiyot-role
rules:
- apiGroups:
  - ""
  resources:
  - endpoints
  - services
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - ""
  resources:
  - pods
  verbs:
  - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kiyot
roleRef:
  kind: ClusterRole
  name: kiyot-role
  apiGroup: rbac.authorization.k8s.io
subjects:
- kind: ServiceAccount
  name: kiyot
  namespace: kube-system
---
apiVersion: extensions/v1beta1
kind: DaemonSet
metadata:
  name: kiyot
  namespace: kube-system
spec:
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        name: kiyot
    spec:
      priorityClassName: "system-node-critical"
      nodeSelector:
        kubernetes.io/role: milpa-worker
      restartPolicy: Always
      hostNetwork: true
      serviceAccountName: kiyot
      initContainers:
      - name: milpa-init
        image: elotl/milpa
        command:
        - bash
        - -c
        - "/milpa-init.sh /shared/milpa"
        volumeMounts:
        - name: shared
          mountPath: /shared
        - name: server-yml
          mountPath: /etc/milpa
      containers:
      - name: kiyot
        image: elotl/milpa
        command:
        - /kiyot
        - --stderrthreshold=1
        - --logtostderr
        - --cert-dir=/shared/milpa/certs
        - --listen=/run/milpa/kiyot.sock
        - --milpa-endpoint=127.0.0.1:54555
        - --service-cluster-ip-range=\$(SERVICE_CIDR)
        - --kubeconfig=
        env:
        - name: SERVICE_CIDR
          valueFrom:
            configMapKeyRef:
              name: milpa-config
              key: SERVICE_CIDR
        securityContext:
          privileged: true
        volumeMounts:
        - name: shared
          mountPath: /shared
        - name: run-milpa
          mountPath: /run/milpa
        - name: log-pods
          mountPath: /var/log/pods
        - name: kubelet-pods
          mountPath: /var/lib/kubelet/pods
        - name: xtables-lock
          mountPath: /run/xtables.lock
        - name: lib-modules
          mountPath: /lib/modules
          readOnly: true
      - name: milpa
        image: elotl/milpa
        command:
        - /milpa
        - --stderrthreshold=1
        - --logtostderr
        - --cert-dir=/shared/milpa/certs
        - --config=/etc/milpa/server.yml
        volumeMounts:
        - name: shared
          mountPath: /shared
        - name: server-yml
          mountPath: /etc/milpa
        - name: etc-machineid
          mountPath: /etc/machine-id
          readOnly: true
      volumes:
      - name: shared
        emptyDir: {}
      - name: server-yml
        configMap:
          name: milpa-config
          items:
          - key: server.yml
            path: server.yml
            mode: 0600
      - name: etc-machineid
        hostPath:
          path: /etc/machine-id
      - name: run-milpa
        hostPath:
          path: /run/milpa
      - name: kubelet-pods
        hostPath:
          path: /var/lib/kubelet/pods
      - name: log-pods
        hostPath:
          path: /var/log/pods
      - name: xtables-lock
        hostPath:
          path: /run/xtables.lock
          type: FileOrCreate
      - name: lib-modules
        hostPath:
          path: /lib/modules
EOF
kubectl apply -f /tmp/kiyot-ds.yaml
