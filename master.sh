#!/bin/bash -v

curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat <<EOF > /etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
apt-get update
apt-get install -y kubelet="${k8s_version}*" kubeadm="${k8s_version}*" kubectl="${k8s_version}*" kubernetes-cni docker.io python-pip jq

# Docker sets the policy for the FORWARD chain to DROP, change it back.
iptables -P FORWARD ACCEPT

name=""
while [[ -z "$name" ]]; do
    sleep 1
    name="$(hostname -f)"
done

if [ -z k8s_version ]; then
    k8s_version=$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)
else
    k8s_version=v${k8s_version}
fi

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
kubernetesVersion: "${k8s_version}"
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
        elotl.co/milpa-worker: ""
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
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kiyot-device-plugin
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: kiyot-device-plugin
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        name: kiyot-device-plugin
    spec:
      priorityClassName: "system-node-critical"
      nodeSelector:
        elotl.co/milpa-worker: ""
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
      internal:
        dataDir: /opt/milpa/data
    nodes:
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
  - nodes
  verbs:
  - get
  - list
- apiGroups:
  - apiextensions.k8s.io
  resources:
  - customresourcedefinitions
  verbs:
    - get
    - list
    - watch
    - create
    - delete
    - deletecollection
    - patch
    - update
- apiGroups:
  - kiyot.elotl.co
  resources:
  - cells
  verbs:
    - get
    - list
    - watch
    - create
    - delete
    - deletecollection
    - patch
    - update
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
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kiyot
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: kiyot
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        name: kiyot
    spec:
      priorityClassName: "system-node-critical"
      nodeSelector:
        elotl.co/milpa-worker: ""
      restartPolicy: Always
      hostNetwork: true
      serviceAccountName: kiyot
      initContainers:
      - name: milpa-init
        image: ${milpa_image}
        command:
        - bash
        - -c
        - "/milpa-init.sh /opt/milpa"
        volumeMounts:
        - name: optmilpa
          mountPath: /opt/milpa
        - name: server-yml
          mountPath: /etc/milpa
      containers:
      - name: kiyot
        image: ${milpa_image}
        command:
        - /kiyot
        - --stderrthreshold=1
        - --logtostderr
        - --cert-dir=/opt/milpa/certs
        - --listen=/run/milpa/kiyot.sock
        - --milpa-endpoint=127.0.0.1:54555
        - --service-cluster-ip-range=\$(SERVICE_CIDR)
        - --kubeconfig=
        - --host-rootfs=/host-rootfs
        env:
        - name: SERVICE_CIDR
          valueFrom:
            configMapKeyRef:
              name: milpa-config
              key: SERVICE_CIDR
        securityContext:
          privileged: true
        volumeMounts:
        - name: optmilpa
          mountPath: /opt/milpa
        - name: run-milpa
          mountPath: /run/milpa
        - name: host-rootfs
          mountPath: /host-rootfs
          mountPropagation: HostToContainer
        - name: xtables-lock
          mountPath: /run/xtables.lock
        - name: lib-modules
          mountPath: /lib/modules
          readOnly: true
      - name: milpa
        image: ${milpa_image}
        command:
        - /milpa
        - --stderrthreshold=1
        - --logtostderr
        - --cert-dir=/opt/milpa/certs
        - --config=/etc/milpa/server.yml
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              apiVersion: v1
              fieldPath: spec.nodeName
        volumeMounts:
        - name: optmilpa
          mountPath: /opt/milpa
        - name: server-yml
          mountPath: /etc/milpa
        - name: etc-machineid
          mountPath: /etc/machine-id
          readOnly: true
      volumes:
      - name: optmilpa
        hostPath:
          path: /opt/milpa
          type: DirectoryOrCreate
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
      - name: host-rootfs
        hostPath:
          path: /
      - name: xtables-lock
        hostPath:
          path: /run/xtables.lock
          type: FileOrCreate
      - name: lib-modules
        hostPath:
          path: /lib/modules
EOF
kubectl apply -f /tmp/kiyot-ds.yaml

service=kiyot-webhook-svc
secret=kiyot-webhook-certs
namespace=kube-system
csrName=$service.$namespace
tmpdir=$(mktemp -d)

cat <<EOF >> $tmpdir/csr.conf
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = $service
DNS.2 = $service.$namespace
DNS.3 = $service.$namespace.svc
EOF

openssl genrsa -out $tmpdir/server-key.pem 2048
openssl req -new -key $tmpdir/server-key.pem -subj "/CN=$service.$namespace.svc" -out $tmpdir/server.csr -config $tmpdir/csr.conf

# clean up any previously created CSR for our service
kubectl delete csr $csrName 2>/dev/null || true

# create server cert/key CSR and send to k8s API
cat <<EOF | kubectl create -f -
apiVersion: certificates.k8s.io/v1beta1
kind: CertificateSigningRequest
metadata:
  name: $csrName
spec:
  groups:
  - system:authenticated
  request: $(cat $tmpdir/server.csr | base64 | tr -d '\n')
  usages:
  - digital signature
  - key encipherment
  - server auth
EOF

# verify CSR has been created
while true; do
    kubectl get csr $csrName
    if [ "$?" -eq 0 ]; then
        break
    fi
done

# approve and fetch the signed certificate
kubectl certificate approve $csrName
# verify certificate has been signed
for x in $(seq 300); do
    serverCert=$(kubectl get csr $csrName -o jsonpath='{.status.certificate}')
    if [[ $serverCert != '' ]]; then
        break
    fi
    sleep 1
done
if [[ $serverCert == '' ]]; then
    echo "ERROR: After approving csr $csrName, the signed certificate did not appear on the resource." >&2
    exit 1
fi
echo $serverCert | openssl base64 -d -A -out $tmpdir/server-cert.pem

# create the secret with CA cert and server cert/key
kubectl create secret generic $secret \
        --from-file=key.pem=$tmpdir/server-key.pem \
        --from-file=cert.pem=$tmpdir/server-cert.pem \
        --dry-run -o yaml |
    kubectl -n $namespace apply -f -

export CA_BUNDLE=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[].cluster.certificate-authority-data}')

manifest=$(cat <<'EOF'
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kiyot-webhook
  namespace: kube-system
  labels:
    app: kiyot-webhook
spec:
  selector:
    matchLabels:
      app: kiyot-webhook
  replicas: 1
  template:
    metadata:
      labels:
        app: kiyot-webhook
    spec:
      containers:
        - name: kiyot-webhook
          image: elotl/kiyot-webhook
          imagePullPolicy: Always
          args:
            - -tlsCertFile=/etc/webhook/certs/cert.pem
            - -tlsKeyFile=/etc/webhook/certs/key.pem
            - -alsologtostderr
            - -v=4
            - 2>&1
          volumeMounts:
            - name: webhook-certs
              mountPath: /etc/webhook/certs
              readOnly: true
      volumes:
        - name: webhook-certs
          secret:
            secretName: kiyot-webhook-certs
---
apiVersion: admissionregistration.k8s.io/v1beta1
kind: MutatingWebhookConfiguration
metadata:
  name: kiyot-webhook-cfg
  labels:
    app: kiyot-webhook
webhooks:
  - name: kiyot-webhook.elotl.co
    clientConfig:
      service:
        name: kiyot-webhook-svc
        namespace: kube-system
        path: "/mutate"
      caBundle: $CA_BUNDLE
    rules:
      - operations: [ "CREATE" ]
        apiGroups: [""]
        apiVersions: ["v1"]
        resources: ["pods"]
---
apiVersion: v1
kind: Service
metadata:
  name: kiyot-webhook-svc
  namespace: kube-system
  labels:
    app: kiyot-webhook
spec:
  ports:
  - port: 443
    targetPort: 443
  selector:
    app: kiyot-webhook
EOF
)
if command -v envsubst >/dev/null 2>&1; then
    echo "$manifest" | envsubst | kubectl apply -f -
else
    echo "$manifest" | sed -e "s|\$CA_BUNDLE|$CA_BUNDLE|g" | kubectl apply -f -
fi
