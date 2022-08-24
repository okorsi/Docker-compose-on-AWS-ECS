### Docker compose on AWS ECS with Hasura and Postgres




configure the environment variables with a correct pair of AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
````bash
export AWS_ACCESS_KEY_ID="Your Access Key"
export AWS_SECRET_ACCESS_KEY="Your Secret Access Key"
export AWS_DEFAULT_REGION=us-west-2
`````

configure an ECS-profile 
"configure.sh"
```bash
#!/bin/bash
set -e
PROFILE_NAME=rampup
CLUSTER_NAME=rampup-cluster
REGION=us-west-2
LAUNCH_TYPE=EC2
ecs-cli configure profile --profile-name "$PROFILE_NAME" --access-key "$AWS_ACCESS_KEY_ID" --secret-key "$AWS_SECRET_ACCESS_KEY"
ecs-cli configure --cluster "$CLUSTER_NAME" --default-launch-type "$LAUNCH_TYPE" --region "$REGION" --config-name "$PROFILE_NAME"
````

Creation of a key pair
```bash
aws ec2 create-key-pair --key-name rampup-cluster \
 --query 'KeyMaterial' --output text > ~/.ssh/rampup-cluster.pem
 ````
 
Creation of the Cluster rampup-cluster with 2 ec2-instances t2.micro
"create-cluster.sh"
```bash
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
````

Result:
```bash
INFO[0004] Using recommended Amazon Linux 2 AMI with ECS Agent 1.61.3 and Docker version 20.10.13
INFO[0004] Created cluster                               cluster=rampup-cluster region=us-west-2
INFO[0006] Waiting for your cluster resources to be created...
INFO[0007] Cloudformation stack status                   stackStatus=CREATE_IN_PROGRESS
INFO[0070] Cloudformation stack status                   stackStatus=CREATE_IN_PROGRESS
INFO[0133] Cloudformation stack status                   stackStatus=CREATE_IN_PROGRESS
VPC created: vpc-xxxx
Security Group created: sg-xxxx
Subnet created: subnet-xxxx
Subnet created: subnet-xxxx
Cluster creation succeeded.
````

This command create:

A new public VPC\
An internet gateway\
The routing tables\
2 public subnets in 2 availability zones\
1 security group\
1 autoscaling group\
2 ec2 instances\
1 ecs cluster

<img width="1048" alt="create-cluster" src="https://user-images.githubusercontent.com/106388100/186400076-512c0dbd-98f3-4e2d-b94f-9014e77bd8de.png">

 Add a persistent layer to cluster:
 Create an EFS file system named "hasura-db-file-system"
 ```bash
 aws efs create-file-system \
    --performance-mode generalPurpose \
    --throughput-mode bursting \
    --encrypted \
    --tags Key=Name,Value=hasura-db-filesystem
 ````
 
 Results:
 ```bash
{
    "OwnerId": "xxxx",
    "CreationToken": "3ade8273-9a5f-4507-b6ce-9c9e11e26546",
    "FileSystemId": "fs-0d8d12d7c1bab3662",
    "FileSystemArn": "arn:aws:elasticfilesystem:us-west-2:xxxx:file-system/fs-0d8d12d7c1bab3662",
    "CreationTime": "2022-08-24T13:40:09+02:00",
    "LifeCycleState": "creating",
    "Name": "hasura-db-filesystem",
    "NumberOfMountTargets": 0,
    "SizeInBytes": {
        "Value": 0,
        "ValueInIA": 0,
        "ValueInStandard": 0
    },
    "PerformanceMode": "generalPurpose",
    "Encrypted": true,
    "KmsKeyId": "arn:aws:kms:us-west-2:xxxx:key/f767211a-c4f3-44b2-8d71-a84ccc876c02",
    "ThroughputMode": "bursting",
    "Tags": [
        {
            "Key": "Name",
            "Value": "hasura-db-filesystem"
        }
    ]
}
````

Configure the connection between the EFS and the cluster
```bash
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
````

Create file "docker-compose.yml"
```bash
version: '3'
services:
  postgres:
    image: postgres:12
    restart: always
    volumes:
    - db_data:/var/lib/postgresql/data
    environment:
      POSTGRES_PASSWORD: postgrespassword
    logging:
      driver: awslogs
      options:
         awslogs-group: rampup
         awslogs-region: us-west-2
         awslogs-stream-prefix: hasura-postgres
  graphql-engine:
    image: hasura/graphql-engine:v1.3.3
    ports:
    - "80:8080"
    depends_on:
    - "postgres"
    links:
      - postgres
    restart: always
    environment:
      HASURA_GRAPHQL_DATABASE_URL: postgres://postgres:postgrespassword@postgres:5432/postgres
      ## enable the console served by server
      HASURA_GRAPHQL_ENABLE_CONSOLE: "true" # set to "false" to disable console
      ## enable debugging mode. It is recommended to disable this in production
      HASURA_GRAPHQL_DEV_MODE: "true"
      HASURA_GRAPHQL_ENABLED_LOG_TYPES: startup, http-log, webhook-log, websocket-log, query-log
      ## uncomment next line to set an admin secret
      # HASURA_GRAPHQL_ADMIN_SECRET: myadminsecretkey
    logging:
      driver: awslogs
      options:
         awslogs-group: rampup
         awslogs-region: us-west-2
         awslogs-stream-prefix: hasura
volumes:
  db_data:
`````

create a file "ecs-params.yml" to specify extra parameters:
```bash
version: 1
task_definition:
  ecs_network_mode: bridge
  efs_volumes:
    - name: db_data
      filesystem_id: fs-0d8d12d7c1bab3662
      transit_encryption: ENABLED
````

then launch the stack:
```bash
#!/bin/sh
ecs-cli compose --project-name rampup  --file docker-compose.yml \
--debug service up  \
--deployment-max-percent 100 --deployment-min-healthy-percent 0 \
--region us-west-2 --ecs-profile rampup --cluster-config rampup \
--create-log-groups
````

Results:
```bash
DEBU[0000] Parsing the compose yaml...
DEBU[0000] Docker Compose version found: 3
DEBU[0000] Parsing v3 project...
WARN[0000] Skipping unsupported YAML option for service...  option name=restart service name=postgres
WARN[0000] Skipping unsupported YAML option for service...  option name=depends_on service name=graphql-engine
WARN[0000] Skipping unsupported YAML option for service...  option name=restart service name=graphql-engine
DEBU[0000] Parsing the ecs-params yaml...
DEBU[0000] Parsing the ecs-registry-creds yaml...
DEBU[0000] Transforming yaml to task definition...
DEBU[0004] Finding task definition in cache or creating if needed  TaskDefinition="{\n  ContainerDefinitions: [{\n      Command: [],\n      Cpu: 0,\n      DnsSearchDomains: [],\n      DnsServers: [],\n      DockerSecurityOptions: [],\n      EntryPoint: [],\n      Environment: [{\n          Name: \"POSTGRES_PASSWORD\",\n          Value: \"postgrespassword\"\n        }],\n      Essential: true,\n      ExtraHosts: [],\n      Image: \"postgres:12\",\n      Links: [],\n      LinuxParameters: {\n        Capabilities: {\n\n        },\n        Devices: []\n      },\n      Memory: 512,\n      MountPoints: [{\n          ContainerPath: \"/var/lib/postgresql/data\",\n          ReadOnly: false,\n          SourceVolume: \"db_data\"\n        }],\n      Name: \"postgres\",\n      Privileged: false,\n      PseudoTerminal: false,\n      ReadonlyRootFilesystem: false\n    },{\n      Command: [],\n      Cpu: 0,\n      DnsSearchDomains: [],\n      DnsServers: [],\n      DockerSecurityOptions: [],\n      EntryPoint: [],\n      Environment: [\n        {\n          Name: \"HASURA_GRAPHQL_ENABLED_LOG_TYPES\",\n          Value: \"startup, http-log, webhook-log, websocket-log, query-log\"\n        },\n        {\n          Name: \"HASURA_GRAPHQL_DATABASE_URL\",\n          Value: \"postgres://postgres:postgrespassword@postgres:5432/postgres\"\n        },\n        {\n          Name: \"HASURA_GRAPHQL_ENABLE_CONSOLE\",\n          Value: \"true\"\n        },\n        {\n          Name: \"HASURA_GRAPHQL_DEV_MODE\",\n          Value: \"true\"\n        }\n      ],\n      Essential: true,\n      ExtraHosts: [],\n      Image: \"hasura/graphql-engine:v1.3.3\",\n      Links: [],\n      LinuxParameters: {\n        Capabilities: {\n\n        },\n        Devices: []\n      },\n      Memory: 512,\n      Name: \"graphql-engine\",\n      PortMappings: [{\n          ContainerPort: 8080,\n          HostPort: 80,\n          Protocol: \"tcp\"\n        }],\n      Privileged: false,\n      PseudoTerminal: false,\n      ReadonlyRootFilesystem: false\n    }],\n  Cpu: \"\",\n  ExecutionRoleArn: \"\",\n  Family: \"rampup\",\n  Memory: \"\",\n  NetworkMode: \"\",\n  RequiresCompatibilities: [\"EC2\"],\n  TaskRoleArn: \"\",\n  Volumes: [{\n      Name: \"db_data\"\n    }]\n}"
DEBU[0005] cache miss                                    taskDef="{\n\n}" taskDefHash=4e57f367846e8f3546dd07eadc605490
INFO[0005] Using ECS task definition                     TaskDefinition="rampup:4"
WARN[0005] No log groups to create; no containers use 'awslogs'
INFO[0005] Updated the ECS service with a new task definition. Old containers will be stopped automatically, and replaced with new ones  deployment-max-percent=100 deployment-min-healthy-percent=0 desiredCount=1 force-deployment=false service=rampup
INFO[0006] Service status                                desiredCount=1 runningCount=1 serviceName=rampup
INFO[0027] Service status                                desiredCount=1 runningCount=0 serviceName=rampup
INFO[0027] (service rampup) has stopped 1 running tasks: (task ee882a6a66724415a3bdc8fffaa2824c).  timestamp="2021-03-08 07:30:33 +0000 UTC"
INFO[0037] (service rampup) has started 1 tasks: (task a1068efe89614812a3243521c0d30847).  timestamp="2022-08-18 07:30:43 +0000 UTC"
INFO[0074] (service rampup) has started 1 tasks: (task 1949af75ac5a4e749dfedcb89321fd67).  timestamp="2022-08-18 07:31:23 +0000 UTC"
INFO[0080] Service status                                desiredCount=1 runningCount=1 serviceName=rampup
INFO[0080] ECS Service has reached a stable state        desiredCount=1 runningCount=1 serviceName=rampup
````

verify that our container are running on AWS ECS Cluster
```bash
ecs-cli ps
````

Results
```bash
Name                                                              State                  Ports                       TaskDefinition  Health
rampup-cluster/00d7ff5191dd4d11a9b52ea64fb9ee26/graphql-engine  RUNNING                34.217.107.14:80->8080/tcp  rampup:10     UNKNOWN
rampup-cluster/00d7ff5191dd4d11a9b52ea64fb9ee26/postgres        RUNNING                                            rampup:10     UNKNOWN

````
open webpage
```bash
open http://34.217.107.14
`````

<img width="1246" alt="hasura-aws" src="https://user-images.githubusercontent.com/106388100/186417256-025c7898-daf6-4466-a781-e3e8981f0dc6.png">

 Open the port 22 to connect to the EC2 instances of the cluster
 ```bash
 #!/bin/sh
# Get my IP
myip="$(dig +short myip.opendns.com @resolver1.opendns.com)"

# Get the security group
sg="$(aws ec2 describe-security-groups   --filters Name=tag:project,Values=rampup-cluster | jq '.SecurityGroups[].GroupId' | sed s/\"//g)"

# Add port 22 to the Security Group of the VPC
aws ec2 authorize-security-group-ingress \
        --group-id $sg \
        --protocol tcp \
        --port 22 \
        --cidr "$myip/32" | jq '.'
 `````
 
 Connection to the instance
 ```bash
 chmod 400 ~/.ssh/rampup-cluster.pem
ssh -i ~/.ssh/rampup-cluster.pem ec2-user@34.217.107.14
 ````


