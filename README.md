## kubeadm quickstart on aws

This is a quickstart to get running with the new kubeadm tool which delivered in Kubernetes 1.4. Please see docs here for information about this new tool: http://kubernetes.io/docs/getting-started-guides/kubeadm/

The goal of this project is to build out a simple cluster on AWS utilizing Terraform to build out infrastructure, then use kubeadm to bootstrap a Kubernetes cluster.

### How it works

The terraform script builds out a new VPC in your account and 3 corresponding subnets. It will also provision an internet gateway and setup a routing table to allow internet access.

#### _NOTE: This isn't ready for production!_

### Run it!

1. Clone the repo: `git clone https://github.com/upmc-enterprises/kubeadm-aws.git`
- [Install Terraform](https://www.terraform.io/intro/getting-started/install.html)
- Update the `main.tf` file with your aws credentials
- Update the `main.tf` file with your [keypair](http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-key-pairs.html) used to connect to the EC2
- Build out infrastructure: `terraform apply`
- SSH to master node get the init token: `cat /var/log/cloud-init-output.log`
- SSH to each worker node and run the command found on the master node (e.g. `kubeadm join --token <token> <master-ip>`)
- From the master, install pod network: `kubectl apply -f https://git.io/weave-kube
daemonset "weave-net" created`

### About

Built by UPMC Enterprises in Pittsburgh, PA. http://enterprises.upmc.com/
