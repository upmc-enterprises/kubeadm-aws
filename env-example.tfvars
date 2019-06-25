# The name of the cluster.
cluster-name = "mycluster"
# The access keys Milpa will use to create instances on AWS. Comment out or
# leave empty to have Kubernetes and Milpa use IAM.
#aws-access-key-id = ""
#aws-secret-access-key = ""
# The name of an already existing SSH key on EC2. This will be added to the
# EC2 instances for SSH access. See
# https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-key-pairs.html on how
# to create or import one to EC2.
ssh-key-name = "my-ssh-key"
# License information for Milpa. Request a free license at
# https://www.elotl.co/trial.
license-key = "FILL_IN"
license-id = "FILL_IN"
license-username = "FILL_IN"
license-password = "FILL_IN"
# Optional parameter. URL to fetch the installer from.
#milpa-installer-url = ""
# Optional parameters. URL and version of the Milpa node agent.
#itzo-url = ""
#itzo-version = ""
# Specify the number of regular kubelet worker nodes.
#workers = 0
# Specify the number of Milpa worker nodes. Right now only 0 or 1 are
# supported.
#milpa-workers = 1
