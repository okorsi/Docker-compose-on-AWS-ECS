#!/bin/sh
#  persistent layer an EFS file system named

aws efs create-file-system \
    --performance-mode generalPurpose \
    --throughput-mode bursting \
    --encrypted \
    --tags Key=Name,Value=hasura-db-filesystem