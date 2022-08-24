#!/bin/sh
ecs-cli compose --project-name rampup  --file docker-compose.yml \
--debug service up  \
--deployment-max-percent 100 --deployment-min-healthy-percent 0 \
--region us-west-2 --ecs-profile rampup --cluster-config rampup \
--create-log-groups