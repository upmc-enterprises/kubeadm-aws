#!/bin/bash
#
# Remove leftover cloud resources created by a Milpa controller.
#

function usage() {
    {
        echo "Usage $0 <vpc-id> <milpa-nametag>"
        echo "You can also set the environment variables VPC_ID and NAMETAG."
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
    NAMETAG="$1"
fi
if [[ -z "$NAMETAG" ]]; then
    usage
fi
shift

if [[ -n "$1" ]]; then
    usage
fi

check_prg aws
check_prg jq

while true; do
    instances=$(aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:MilpaNametag,Values=$NAMETAG" | jq -r ".Reservations | .[] | .Instances | .[] | .InstanceId")
    if [[ -n "$instances" ]]; then
        echo "Terminating instances:"
        echo "$instances"
        aws ec2 terminate-instances --instance-ids $instances > /dev/null 2>&1
    else
        break
    fi
done

sgs=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:MilpaNametag,Values=$NAMETAG" | jq -r ".SecurityGroups | .[] | .GroupId")
if [[ -n "$sgs" ]]; then
    echo "Removing SGs:"
    echo "$sgs"
    for sg in $sgs; do
        aws ec2 delete-security-group --group-id $sg > /dev/null 2>&1
    done
fi

exit 0
