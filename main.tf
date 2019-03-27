
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

resource "aws_vpc" "main" {
    cidr_block = "10.0.0.0/16"
    enable_dns_hostnames = true

    tags {
        Name = "TF_VPC"
    }

    provisioner "local-exec" {
        # Remove any leftover instance, security group etc Milpa created. They
        # would prevent terraform from destroying the VPC.
        when    = "destroy"
        command = "./cleanup-vpc.sh ${self.id} ${var.cluster-name} > /dev/null 2>&1"
        interpreter = ["/bin/bash", "-c"]
        environment = {
            USE_AWS_ACCESS_KEY_ID = "${var.aws-access-key-id}"
            USE_AWS_SECRET_ACCESS_KEY = "${var.aws-secret-access-key}"
        }
    }
}

resource "aws_internet_gateway" "gw" {
    vpc_id = "${aws_vpc.main.id}"

    tags {
        Name = "TF_main"
    }

    provisioner "local-exec" {
        # Remove any leftover instance, security group etc Milpa created. They
        # would prevent terraform from destroying the VPC.
        when    = "destroy"
        command = "./cleanup-vpc.sh ${self.vpc_id} ${var.cluster-name} > /dev/null 2>&1"
        interpreter = ["/bin/bash", "-c"]
        environment = {
            USE_AWS_ACCESS_KEY_ID = "${var.aws-access-key-id}"
            USE_AWS_SECRET_ACCESS_KEY = "${var.aws-secret-access-key}"
        }
    }
}

resource "aws_route_table" "r" {
    vpc_id = "${aws_vpc.main.id}"
    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = "${aws_internet_gateway.gw.id}"
    }

    depends_on = ["aws_internet_gateway.gw"]

    tags {
        Name = "TF_main"
    }
}

resource "aws_route_table_association" "publicA" {
    subnet_id = "${aws_subnet.publicA.id}"
    route_table_id = "${aws_route_table.r.id}"
}

resource "aws_subnet" "publicA" {
    vpc_id = "${aws_vpc.main.id}"
    cidr_block = "10.0.100.0/24"
    availability_zone = "us-east-1c"
    map_public_ip_on_launch = true

    tags {
        Name = "TF_PubSubnetA"
    }
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
      cidr_blocks = ["10.0.0.0/16"]
  }


  egress {
      from_port = 0
      to_port = 0
      protocol = "-1"
      cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name = "kubernetes"
  }
}

data "template_file" "master-userdata" {
    template = "${file("${var.master-userdata}")}"

    vars {
        k8stoken = "${var.k8stoken}"
    }
}

data "template_file" "worker-userdata" {
    template = "${file("${var.worker-userdata}")}"

    vars {
        k8stoken = "${var.k8stoken}"
        masterIP = "${aws_instance.k8s-master.private_ip}"
        cluster_name = "${var.cluster-name}"
        aws_access_key_id = "${var.aws-access-key-id}"
        aws_secret_access_key = "${var.aws-secret-access-key}"
        ssh_key_name = "${var.ssh-key-name}"
        license_key = "${var.license-key}"
        license_id = "${var.license-id}"
        license_username = "${var.license-username}"
        license_password = "${var.license-password}"
    }
}

resource "aws_instance" "k8s-master" {
  ami           = "ami-2ef48339"
  instance_type = "t2.medium"
  subnet_id = "${aws_subnet.publicA.id}"
  user_data = "${data.template_file.master-userdata.rendered}"
  key_name = "${var.ssh-key-name}"
  associate_public_ip_address = true
  vpc_security_group_ids = ["${aws_security_group.kubernetes.id}"]

  depends_on = ["aws_internet_gateway.gw"]

  tags {
      Name = "k8s-master"
  }
}

resource "aws_instance" "k8s-worker" {
  ami           = "ami-2ef48339"
  instance_type = "t2.medium"
  subnet_id = "${aws_subnet.publicA.id}"
  user_data = "${data.template_file.worker-userdata.rendered}"
  key_name = "${var.ssh-key-name}"
  associate_public_ip_address = true
  vpc_security_group_ids = ["${aws_security_group.kubernetes.id}"]

  depends_on = ["aws_internet_gateway.gw"]

  tags {
      Name = "k8s-worker"
  }
}
