# Simple Nodeless Kubernetes Cluster with Milpa

Note: this is based on [upmc-enterprises/kubeadm-aws](https://github.com/upmc-enterprises/kubeadm-aws).

This is a Terraform configuration for provisioning a simple (one master, one worker) nodeless Kubernetes cluster that uses [Milpa](https://www.elotl.co/kiyotdocs) as its container runtime.

## Setup

Create a file at `~/env.tfvars`:

```
$ cp env-example.tfvars ~/env.tfvars
$ vi ~/env.tfvars
```

Fill in all the required variables, then apply the configuration:

    $ terraform init # Only needed the first time.
    [...]
    $ terraform apply -var-file ~/env.tfvars
    [...]
    Apply complete! Resources: 8 added, 0 changed, 0 destroyed.
    
    Outputs:
    
    master_ip = 3.81.184.107
    worker_ip = 54.90.138.204

This will create a cluster with one master and one worker.

SSH into the master node and check the status of the cluster:

    ubuntu@ip-10-0-100-66:~$ kubectl cluster-info
    Kubernetes master is running at https://10.0.100.66:6443
    KubeDNS is running at https://10.0.100.66:6443/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
    
    To further debug and diagnose cluster problems, use 'kubectl cluster-info dump'.
    ubuntu@ip-10-0-100-66:~$ kubectl get nodes
    NAME              STATUS   ROLES    AGE   VERSION
    ip-10-0-100-135   Ready    <none>   62s   v1.14.0
    ip-10-0-100-66    Ready    master   97s   v1.14.0
    ubuntu@ip-10-0-100-66:~$

At this point, the cluster is ready to use. Pods will be scheduled to run in EC2 instances, instead of containers on the worker node.

## Teardown

Make sure all pods and services are removed. On the master:

    ubuntu@ip-10-0-100-66:~$ for ns in $(kubectl get namespaces | tail -n+2 | awk '{print $1}'); do kubectl delete --all deployments --namespace=$ns; kubectl delete --all services --namespace=$ns; kubectl delete --all daemonsets --namespace=$ns; kubectl delete --all pods --namespace=$ns; done
    No resources found
    service "kubernetes" deleted
    No resources found
    No resources found
    [...]
    ubuntu@ip-10-0-100-66:~$

Then you can log out from the master, and use Terraform to tear down the infrastructure:

    $ terraform destroy -var-file ~/env.tfvars
    [...]
    Plan: 0 to add, 0 to change, 8 to destroy.
    
    Do you really want to destroy all resources?
      Terraform will destroy all your managed infrastructure, as shown above.
      There is no undo. Only 'yes' will be accepted to confirm.
    
      Enter a value: yes

    [...]

    Destroy complete! Resources: 8 destroyed.
