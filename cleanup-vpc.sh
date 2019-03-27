#!/bin/bash
#
# Remove leftover Milpa cloud resources from an AWS VPC.
#

function usage() {
    echo "Usage $0 <vpc-id> <milpa-cluster-name>"
    echo "You can also set the environment variables VPC_ID and CLUSTER_NAME."
    exit 1
}

function check_prg() {
    $1 --version || {
        echo "Can't find $prg."
        exit 2
    }
}

if [[ "$1" != "" ]]; then
    VPC_ID="$1"
fi
if [[ -z "$VPC_ID" ]]; then
    usage
fi
shift

if [[ "$1" != "" ]]; then
    CLUSTER_NAME="$1"
fi
if [[ -z "$CLUSTER_NAME" ]]; then
    usage
fi
shift

if [[ -n "$1" ]]; then
    usage
fi

check_prg aws
check_prg jq

if [[ -n "$USE_AWS_ACCESS_KEY_ID" ]]; then
    export AWS_ACCESS_KEY_ID="$USE_AWS_ACCESS_KEY_ID"
fi

if [[ -n "$USE_AWS_SECRET_ACCESS_KEY" ]]; then
    export AWS_SECRET_ACCESS_KEY="$USE_AWS_SECRET_ACCESS_KEY"
fi

# Delete instances in VPC.
while true; do
    instances=$(aws ec2 describe-instances | jq -r ".Reservations | .[] | .Instances | .[] | select(.State.Name!=\"shutting-down\") | select(.State.Name!=\"terminated\") | select(.VpcId==\"$VPC_ID\") | select(.Tags) | select(.Tags[] | contains({\"Key\":\"MilpaClusterName\",\"Value\":\"$CLUSTER_NAME\"})) | .InstanceId")
    if [[ "$instances" != "" ]]; then
        echo "Terminating instances \"$instances\""
        aws ec2 terminate-instances --instance-ids $instances
    else
        break
    fi
done

# Delete LBs.
while true; do
    lbs=$(aws elb describe-load-balancers | jq -r ".LoadBalancerDescriptions | .[] | select(.VPCId==\"$VPC_ID\") | select(.Tags) | select(.Tags[] | contains({\"Key\":\"MilpaClusterName\",\"Value\":\"$CLUSTER_NAME\"})) | .LoadBalancerName")
    if [[ "$lbs" != "" ]]; then
        echo "Deleting LBs \"$lbs\""
        for lb in $lbs; do
            aws elb delete-load-balancer --load-balancer-name $lb
        done
    else
        break
    fi
done

# Delete security groups in VPC.
for sg in $(aws ec2 describe-security-groups | jq -r ".SecurityGroups | .[] | select(.VpcId == \"$VPC_ID\") | select(.Tags) | select(.Tags[] | contains({\"Key\":\"MilpaClusterName\",\"Value\":\"$CLUSTER_NAME\"})) | .GroupId"); do
    aws ec2 delete-security-group --group-id $sg
done

exit 0
