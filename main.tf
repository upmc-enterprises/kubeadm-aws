
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
  access_key = "${var.access_key}"
  secret_key = "${var.secret_key}"
  region     = "${var.region}"
}

# Key pair for the instances
resource "aws_key_pair" "ssh-key" {
  key_name = "k8s"
  public_key = "${var.k8s-ssh-key}"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc" "main" {
    cidr_block = "10.0.0.0/16"
    enable_dns_hostnames = true

    tags {
        Name = "TF_VPC"
    }
}

resource "aws_internet_gateway" "gw" {
    vpc_id = "${aws_vpc.main.id}"

    tags {
        Name = "TF_main"
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

resource "aws_route_table_association" "publicB" {
    subnet_id = "${aws_subnet.publicB.id}"
    route_table_id = "${aws_route_table.r.id}"
}

resource "aws_route_table_association" "publicC" {
    subnet_id = "${aws_subnet.publicC.id}"
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

resource "aws_subnet" "publicB" {
    vpc_id = "${aws_vpc.main.id}"
    cidr_block = "10.0.101.0/24"
    availability_zone = "us-east-1d"
    map_public_ip_on_launch = true

    tags {
        Name = "TF_PubSubnetB"
    }
}

resource "aws_subnet" "publicC" {
    vpc_id = "${aws_vpc.main.id}"
    cidr_block = "10.0.102.0/24"
    availability_zone = "us-east-1e"
    map_public_ip_on_launch = true

    tags {
        Name = "TF_PubSubnetC"
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
    }
}

resource "aws_instance" "k8s-master" {
  ami           = "ami-2ef48339"
  instance_type = "t2.medium"
  subnet_id = "${aws_subnet.publicA.id}"
  user_data = "${data.template_file.master-userdata.rendered}"
  key_name = "${aws_key_pair.ssh-key.key_name}"
  associate_public_ip_address = true
  security_groups = ["${aws_security_group.kubernetes.id}"]

  depends_on = ["aws_internet_gateway.gw"]

  tags {
      Name = "[TF] k8s-master"
  }
}

resource "aws_instance" "k8s-worker1" {
  ami           = "ami-2ef48339"
  instance_type = "t2.medium"
  subnet_id = "${aws_subnet.publicA.id}"
  user_data = "${data.template_file.worker-userdata.rendered}"
  key_name = "${aws_key_pair.ssh-key.key_name}"
  associate_public_ip_address = true
  security_groups = ["${aws_security_group.kubernetes.id}"]

  depends_on = ["aws_internet_gateway.gw"]

  tags {
      Name = "worker0"
  }
}

resource "aws_instance" "k8s-worker2" {
  ami           = "ami-2ef48339"
  instance_type = "t2.medium"
  subnet_id = "${aws_subnet.publicA.id}"
  user_data = "${data.template_file.worker-userdata.rendered}"
  key_name = "${aws_key_pair.ssh-key.key_name}"
  associate_public_ip_address = true
  security_groups = ["${aws_security_group.kubernetes.id}"]

  depends_on = ["aws_internet_gateway.gw"]

  tags {
      Name = "worker1"
  }
}
