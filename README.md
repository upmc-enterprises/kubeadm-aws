## kubeadm quickstart on aws

This is a quickstart to get running with the new kubeadm tool which delivered in Kubernetes 1.4. Please see docs here for information about this new tool: http://kubernetes.io/docs/getting-started-guides/kubeadm/

The goal of this project is to build out a simple cluster on AWS utilizing Terraform to build out infrastructure, then use kubeadm to bootstrap a Kubernetes cluster.

### How it works

The terraform script builds out a new VPC in your account and 3 corresponding subnets. It will also provision an internet gateway and setup a routing table to allow internet access.

#### _NOTE: This isn't ready for production!_

### Run it!

1. Clone the repo: `git clone https://github.com/upmc-enterprises/kubeadm-aws.git`
- [Install Terraform](https://www.terraform.io/intro/getting-started/install.html)
- Generate token: `python -c 'import random; print "%0x.%0x" % (random.SystemRandom().getrandbits(3*8), random.SystemRandom().getrandbits(8*8))'`
- Build out infrastructure: `terraform apply -var 'k8stoken=<token>' -var 'access_key=<key>' -var 'secret_key=<secret>' -var 'key_name=keypair'`
- Done!

### About

Built by UPMC Enterprises in Pittsburgh, PA. http://enterprises.upmc.com/
