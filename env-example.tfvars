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
# When you set up a new cluster, generate a token via:
# python -c 'import random; print "%0x.%0x" % (random.SystemRandom().getrandbits(3*8), random.SystemRandom().getrandbits(8*8))'
k8stoken = "e7ea06.8f558c9acdba2743"
# Optional parameter. URL to fetch the installer from.
#milpa-installer-url = ""
# Optional parameters. URL and version of the Milpa node agent.
#itzo-url = ""
#itzo-version = ""
