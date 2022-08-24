#!/bin/sh
# Add mount points to each subnet of the VPC:
aws ec2 describe-subnets --filters Name=tag:project,Values=rampup-cluster \
 | jq ".Subnets[].SubnetId" | \
xargs -ISUBNET  aws efs create-mount-target \
 --file-system-id fs-0d8d12d7c1bab3662 --subnet-id SUBNET

 aws ec2 describe-subnets --filters Name=tag:project,Values=rampup-cluster \
 | jq ".Subnets[].SubnetId" | \
xargs -ISUBNET  aws efs create-mount-target \
 --file-system-id fs-0d8d12d7c1bab3662 --subnet-id SUBNET

# get the security group associated with each mount target
 efs_sg=$(aws efs describe-mount-targets --file-system-id fs-0d8d12d7c1bab3662 \
	| jq ".MountTargets[0].MountTargetId" \
	 | xargs -IMOUNTG aws efs describe-mount-target-security-groups \
	 --mount-target-id MOUNTG | jq ".SecurityGroups[0]" | xargs echo )

# open the TCP port 2049 for the security group of the VPC
 vpc_sg="$(aws ec2 describe-security-groups  \
 --filters Name=tag:project,Values=rampup-cluster \
 | jq '.SecurityGroups[].GroupId' | xargs echo)"

# authorize the TCP/2049 port from the default security group of the VPC
aws ec2 authorize-security-group-ingress \
--group-id $efs_sg \
--protocol tcp \
--port 2049 \
--source-group $vpc_sg \
--region us-west-2
