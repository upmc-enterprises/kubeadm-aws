/*
Copyright (c) 2016, UPMC Enterprises
All rights reserved.
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name UPMC Enterprises nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.
THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL UPMC ENTERPRISES BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PR)
OCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
*/

provider "aws" {
  region     = "${var.region}"
}

locals {
  k8s_cluster_tags = "${map(
    "Name", "kubeadm-milpa-${var.cluster-name}",
    "kubernetes.io/cluster/${var.cluster-name}", "owned"
  )}"
}

data "aws_availability_zones" "available-azs" {
  state = "available"
}

resource "random_shuffle" "azs" {
  input = "${data.aws_availability_zones.available-azs.names}"
  result_count = "${var.number-of-subnets}"
}

resource "aws_vpc" "main" {
  cidr_block = "${var.vpc-cidr}"
  enable_dns_hostnames = true

  tags = "${local.k8s_cluster_tags}"

  provisioner "local-exec" {
    # Remove any leftover instance, security group etc Milpa created. They
    # would prevent terraform from destroying the VPC.
    when    = "destroy"
    command = "./cleanup-vpc.sh ${self.id} ${var.cluster-name}"
    interpreter = ["/bin/bash", "-c"]
    environment = {
      "AWS_REGION" = "${var.region}"
      "AWS_DEFAULT_REGION" = "${var.region}"
    }
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = "${aws_vpc.main.id}"

  tags = "${local.k8s_cluster_tags}"

  provisioner "local-exec" {
    # Remove any leftover instance, security group etc Milpa created. They
    # would prevent terraform from destroying the VPC.
    when    = "destroy"
    command = "./cleanup-vpc.sh ${self.vpc_id} ${var.cluster-name}"
    interpreter = ["/bin/bash", "-c"]
    environment = {
      "AWS_REGION" = "${var.region}"
      "AWS_DEFAULT_REGION" = "${var.region}"
    }
  }
}

resource "aws_subnet" "subnets" {
  count = "${var.number-of-subnets}"
  vpc_id = "${aws_vpc.main.id}"
  cidr_block = "${cidrsubnet("${var.vpc-cidr}", 4, "${count.index+1}")}"
  availability_zone = "${element("${random_shuffle.azs.result}", count.index)}"
  map_public_ip_on_launch = true

  tags = "${local.k8s_cluster_tags}"
}

resource "aws_route_table" "route-table" {
  vpc_id = "${aws_vpc.main.id}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.gw.id}"
  }

  depends_on = ["aws_internet_gateway.gw"]

  tags = "${local.k8s_cluster_tags}"
}

resource "aws_route_table_association" "route-table-to-subnets" {
  count = "${var.number-of-subnets}"
  subnet_id = "${aws_subnet.subnets.*.id[count.index]}"
  route_table_id = "${aws_route_table.route-table.id}"
}

resource "aws_security_group" "kubernetes" {
  name = "kubernetes"
  description = "Allow inbound ssh traffic"
  vpc_id = "${aws_vpc.main.id}"

  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["${var.vpc-cidr}"]
  }

  ingress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["${var.pod-cidr}"]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = "${local.k8s_cluster_tags}"
}

resource "aws_iam_role" "k8s-master" {
  name = "k8s-master-${var.cluster-name}"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "k8s-master" {
  name = "k8s-master-${var.cluster-name}"
  role = "${aws_iam_role.k8s-master.id}"
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeTags",
        "ec2:DescribeInstances",
        "ec2:DescribeRegions",
        "ec2:DescribeRouteTables",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSubnets",
        "ec2:DescribeVolumes",
        "ec2:CreateSecurityGroup",
        "ec2:CreateTags",
        "ec2:CreateVolume",
        "ec2:ModifyInstanceAttribute",
        "ec2:ModifyVolume",
        "ec2:AttachVolume",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:CreateRoute",
        "ec2:DeleteRoute",
        "ec2:DeleteSecurityGroup",
        "ec2:DeleteVolume",
        "ec2:DetachVolume",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:DescribeVpcs",
        "elasticloadbalancing:AddTags",
        "elasticloadbalancing:AttachLoadBalancerToSubnets",
        "elasticloadbalancing:ApplySecurityGroupsToLoadBalancer",
        "elasticloadbalancing:CreateLoadBalancer",
        "elasticloadbalancing:CreateLoadBalancerPolicy",
        "elasticloadbalancing:CreateLoadBalancerListeners",
        "elasticloadbalancing:ConfigureHealthCheck",
        "elasticloadbalancing:DeleteLoadBalancer",
        "elasticloadbalancing:DeleteLoadBalancerListeners",
        "elasticloadbalancing:DescribeLoadBalancers",
        "elasticloadbalancing:DescribeLoadBalancerAttributes",
        "elasticloadbalancing:DetachLoadBalancerFromSubnets",
        "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
        "elasticloadbalancing:ModifyLoadBalancerAttributes",
        "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
        "elasticloadbalancing:SetLoadBalancerPoliciesForBackendServer",
        "elasticloadbalancing:AddTags",
        "elasticloadbalancing:CreateListener",
        "elasticloadbalancing:CreateTargetGroup",
        "elasticloadbalancing:DeleteListener",
        "elasticloadbalancing:DeleteTargetGroup",
        "elasticloadbalancing:DescribeListeners",
        "elasticloadbalancing:DescribeLoadBalancerPolicies",
        "elasticloadbalancing:DescribeTargetGroups",
        "elasticloadbalancing:DescribeTargetHealth",
        "elasticloadbalancing:ModifyListener",
        "elasticloadbalancing:ModifyTargetGroup",
        "elasticloadbalancing:RegisterTargets",
        "elasticloadbalancing:SetLoadBalancerPoliciesOfListener",
        "iam:CreateServiceLinkedRole",
        "kms:DescribeKey"
      ],
      "Resource": [
        "*"
      ]
    }
  ]
}
EOF
}

resource  "aws_iam_instance_profile" "k8s-master" {
  name = "k8s-master-${var.cluster-name}"
  role = "${aws_iam_role.k8s-master.name}"
}

resource "aws_iam_role" "k8s-milpa-worker" {
  name = "k8s-milpa-worker-${var.cluster-name}"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "k8s-milpa-worker" {
  name = "k8s-milpa-worker-${var.cluster-name}"
  role = "${aws_iam_role.k8s-milpa-worker.id}"
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ec2",
      "Effect": "Allow",
      "Action": [
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:CreateRoute",
        "ec2:CreateSecurityGroup",
        "ec2:CreateTags",
        "ec2:CreateVolume",
        "ec2:DeleteRoute",
        "ec2:DeleteSecurityGroup",
        "ec2:DescribeAddresses",
        "ec2:DescribeElasticGpus",
        "ec2:DescribeImages",
        "ec2:DescribeInstances",
        "ec2:DescribeRouteTables",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSpotPriceHistory",
        "ec2:DescribeSubnets",
        "ec2:DescribeTags",
        "ec2:DescribeVolumes",
        "ec2:DescribeVpcAttribute",
        "ec2:DescribeVpcs",
        "ec2:ModifyInstanceAttribute",
        "ec2:ModifyInstanceCreditSpecification",
        "ec2:ModifyVolume",
        "ec2:ModifyVpcAttribute",
        "ec2:RequestSpotInstances",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:RunInstances",
        "ec2:TerminateInstances",
        "ecr:BatchGetImage",
        "ecr:GetAuthorizationToken",
        "ecr:GetDownloadUrlForLayer",
        "elasticloadbalancing:DescribeLoadBalancerAttributes",
        "elasticloadbalancing:DescribeLoadBalancers",
        "elasticloadbalancing:DescribeTags",
        "route53:ChangeResourceRecordSets",
        "route53:CreateHostedZone",
        "route53:GetChange",
        "route53:ListHostedZonesByName",
        "route53:ListResourceRecordSets"
      ],
      "Resource": "*"
    },
    {
      "Sid": "dynamo",
      "Effect": "Allow",
      "Action": [
        "dynamodb:CreateTable",
        "dynamodb:PutItem",
        "dynamodb:DescribeTable",
        "dynamodb:GetItem"
      ],
      "Resource": "arn:aws:dynamodb:*:*:table/MilpaClusters"
    },
    {
      "Sid": "elb",
      "Effect": "Allow",
      "Action": [
        "elasticloadbalancing:DeleteLoadBalancer",
        "elasticloadbalancing:RemoveTags",
        "elasticloadbalancing:CreateLoadBalancer",
        "elasticloadbalancing:ConfigureHealthCheck",
        "elasticloadbalancing:AddTags",
        "elasticloadbalancing:ApplySecurityGroupsToLoadBalancer",
        "elasticloadbalancing:DeleteLoadBalancerListeners",
        "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
        "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
        "elasticloadbalancing:ModifyLoadBalancerAttributes",
        "elasticloadbalancing:CreateLoadBalancerListeners"
      ],
      "Resource": "arn:aws:elasticloadbalancing:*:*:loadbalancer/milpa-*"
    }
  ]
}
EOF
}

resource  "aws_iam_instance_profile" "k8s-milpa-worker" {
  name = "k8s-milpa-worker-${var.cluster-name}"
  role = "${aws_iam_role.k8s-milpa-worker.name}"
}

resource "aws_iam_role" "k8s-worker" {
  name = "k8s-worker-${var.cluster-name}"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "k8s-worker" {
  name = "k8s-worker-${var.cluster-name}"
  role = "${aws_iam_role.k8s-worker.id}"
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeRegions",
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:GetRepositoryPolicy",
        "ecr:DescribeRepositories",
        "ecr:ListImages",
        "ecr:BatchGetImage"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

resource  "aws_iam_instance_profile" "k8s-worker" {
  name = "k8s-worker-${var.cluster-name}"
  role = "${aws_iam_role.k8s-worker.name}"
}

resource "random_id" "k8stoken-prefix" {
  byte_length = 3
}

resource "random_id" "k8stoken-suffix" {
  byte_length = 8
}

locals {
  k8stoken = "${format("%s.%s", random_id.k8stoken-prefix.hex, random_id.k8stoken-suffix.hex)}"
}

data "template_file" "master-userdata" {
  template = "${file("${var.master-userdata}")}"

  vars = {
    k8stoken = "${local.k8stoken}"
    k8s_version = "${var.k8s-version}"
    pod_cidr = "${var.pod-cidr}"
    service_cidr = "${var.service-cidr}"
    subnet_cidrs = "${join(" ", "${aws_subnet.subnets.*.cidr_block}")}"
  }
}

data "template_file" "milpa-worker-userdata" {
  template = "${file("${var.milpa-worker-userdata}")}"
  count = "${var.milpa-workers}"

  vars = {
    k8stoken = "${local.k8stoken}"
    k8s_version = "${var.k8s-version}"
    masterIP = "${aws_instance.k8s-master.private_ip}"
    service_cidr = "${var.service-cidr}"
    cluster_name = "${var.cluster-name}"
    node_nametag = "${var.cluster-name}-${count.index}"
    aws_access_key_id = "${var.aws-access-key-id}"
    aws_secret_access_key = "${var.aws-secret-access-key}"
    default_instance_type = "${var.default-instance-type}"
    default_volume_size = "${var.default-volume-size}"
    boot_image_tags = "${jsonencode("${var.boot-image-tags}")}"
    license_key = "${var.license-key}"
    license_id = "${var.license-id}"
    license_username = "${var.license-username}"
    license_password = "${var.license-password}"
    itzo_url = "${var.itzo-url}"
    itzo_version = "${var.itzo-version}"
    milpa_installer_url = "${var.milpa-installer-url}"
    pod_cidr = "${var.pod-cidr}"
  }
}

data "template_file" "worker-userdata" {
  template = "${file("${var.worker-userdata}")}"

  vars = {
    k8stoken = "${local.k8stoken}"
    k8s_version = "${var.k8s-version}"
    masterIP = "${aws_instance.k8s-master.private_ip}"
    pod_cidr = "${var.pod-cidr}"
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-xenial-16.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical.
}

resource "aws_instance" "k8s-master" {
  ami           = "${data.aws_ami.ubuntu.id}"
  instance_type = "t2.medium"
  subnet_id = "${aws_subnet.subnets.*.id[0]}"
  user_data = "${data.template_file.master-userdata.rendered}"
  key_name = "${var.ssh-key-name}"
  associate_public_ip_address = true
  vpc_security_group_ids = ["${aws_security_group.kubernetes.id}"]
  iam_instance_profile = "${aws_iam_instance_profile.k8s-master.id}"

  depends_on = ["aws_internet_gateway.gw"]

  tags = "${local.k8s_cluster_tags}"
}

resource "aws_instance" "k8s-milpa-worker" {
  ami           = "${data.aws_ami.ubuntu.id}"
  instance_type = "t2.medium"
  count = "${var.milpa-workers}"
  subnet_id = "${element("${aws_subnet.subnets.*.id}", count.index)}"
  user_data = "${element("${data.template_file.milpa-worker-userdata.*.rendered}", count.index)}"
  key_name = "${var.ssh-key-name}"
  associate_public_ip_address = true
  vpc_security_group_ids = ["${aws_security_group.kubernetes.id}"]
  iam_instance_profile = "${aws_iam_instance_profile.k8s-milpa-worker.id}"

  root_block_device {
    volume_size = "${var.worker-disk-size}"
  }

  depends_on = ["aws_internet_gateway.gw"]

  tags = "${local.k8s_cluster_tags}"

  provisioner "local-exec" {
    when = "destroy"
    command = "aws ec2 terminate-instances --instance-ids ${self.id}"
    environment = {
      "AWS_REGION" = "${var.region}"
      "AWS_DEFAULT_REGION" = "${var.region}"
    }
  }
  provisioner "local-exec" {
    when = "destroy"
    command = "aws ec2 describe-instances --filters 'Name=vpc-id,Values=${aws_vpc.main.id}' 'Name=tag:MilpaNametag,Values=${var.cluster-name}-${count.index}' | jq -r '.Reservations | .[] | .Instances | .[] | .InstanceId' | xargs -r aws ec2 terminate-instances --instance-ids"
    environment = {
      "AWS_REGION" = "${var.region}"
      "AWS_DEFAULT_REGION" = "${var.region}"
    }
  }

  lifecycle {
    # This seems like a bug in Terraform or the AWS provider - even though
    # userdata is the same, TF thinks it has changed, which forces a
    # replacement of the instance. Let's ignore userdata changes for now.
    ignore_changes = ["user_data"]
  }
}

resource "aws_instance" "k8s-worker" {
  ami           = "${data.aws_ami.ubuntu.id}"
  instance_type = "t2.medium"
  count = "${var.workers}"
  subnet_id = "${element("${aws_subnet.subnets.*.id}", count.index)}"
  user_data = "${data.template_file.worker-userdata.rendered}"
  key_name = "${var.ssh-key-name}"
  associate_public_ip_address = true
  vpc_security_group_ids = ["${aws_security_group.kubernetes.id}"]
  iam_instance_profile = "${aws_iam_instance_profile.k8s-worker.id}"

  root_block_device {
    volume_size = "${var.worker-disk-size}"
  }

  depends_on = ["aws_internet_gateway.gw"]

  tags = "${local.k8s_cluster_tags}"
}
