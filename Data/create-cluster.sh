#!/bin/bash
KEY_PAIR=rampup-cluster
    ecs-cli up \
      --keypair $KEY_PAIR  \
      --capability-iam \
      --size 2 \
      --instance-type t2.micro \
      --tags project=rampup-cluster,owner=oleksii \
      --cluster-config rampup \
      --ecs-profile rampup
