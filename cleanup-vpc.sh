#!/bin/bash
#
# Remove leftover cloud resources from an AWS VPC.
#

function usage() {
    {
        echo "Usage $0 <vpc-id> <milpa-cluster-name>"
        echo "You can also set the environment variables VPC_ID and CLUSTER_NAME."
    } >&2
    exit 1
}

function check_prg() {
    $1 --version || {
        {
            echo "Can't find $prg."
        } >&2
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

# Delete instances in VPC. Do this in a loop, since Milpa might be still
# creating new instances.
while true; do
    instances=$(aws ec2 describe-instances | jq -r ".Reservations | .[] | .Instances | .[] | select(.State.Name!=\"shutting-down\") | select(.State.Name!=\"terminated\") | select(.VpcId==\"$VPC_ID\") | select(.Tags) | select(.Tags[] | contains({\"Key\":\"MilpaClusterName\",\"Value\":\"$CLUSTER_NAME\"})) | .InstanceId")
    if [[ -n "$instances" ]]; then
        echo "Terminating instances:"
        echo "$instances"
        aws ec2 terminate-instances --instance-ids $instances > /dev/null 2>&1
    else
        break
    fi
done

# Delete LBs.
lbs=$(aws elb describe-load-balancers | jq -r ".LoadBalancerDescriptions | .[] | select(.VPCId==\"$VPC_ID\") | .LoadBalancerName")
if [[ -n "$lbs" ]]; then
    echo "Removing LBs:"
    echo "$lbs"
    for lb in $lbs; do
        aws elb delete-load-balancer --load-balancer-name $lb > /dev/null 2>&1
    done
fi

# Delete security groups in VPC.
sgs=$(aws ec2 describe-security-groups | jq -r ".SecurityGroups | .[] | select(.VpcId == \"$VPC_ID\") | .GroupId")
if [[ -n "$sgs" ]]; then
    echo "Removing SGs:"
    echo "$sgs"
    for sg in $sgs; do
        aws ec2 delete-security-group --group-id $sg > /dev/null 2>&1
    done
fi

exit 0
