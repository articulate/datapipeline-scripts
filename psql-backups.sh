#!/bin/bash

# AWS Data Pipeline RDS backup and verification automation relying on Amazon Linux and S3

# Ensure the return value of a pipeline is the last command to exit with a non-zero status, 
# or zero if all commands in were successful, and exit if a variable is undefined.
set -uo pipefail

export AWS_DEFAULT_REGION=$AWS_REGION

function get_time_now {
  time_now=$(date --utc +%FT%T.%3NZ)
}

# Use trap to print the most recent error message & delete the restore instance
# when the script exits
function cleanup_on_exit {

  #in bash function calls within in a function can be unreliable
  time_now=$(date --utc +%FT%T.%3NZ)
  echo "$time_now Trap EXIT called..."
  echo "$time_now If this script exited prematurely, check stderr for the exit error message"

  # if restore instance exists, delete it
  ERROR=$(aws rds describe-db-instances --db-instance-identifier $DB_INSTANCE_IDENTIFIER 2>&1)
  RET_CODE=$?

  DELETE_RET_CODE=0
  if [[ $RET_CODE == 0 ]]; then
    echo "Deleting restore DB instance $DB_INSTANCE_IDENTIFIER..."
    ERROR=$(aws rds delete-db-instance --db-instance-identifier $DB_INSTANCE_IDENTIFIER \
      --skip-final-snapshot 2>&1)
    RET_CODE=$?
  fi
  
  # this if statement is a catch all for any errors with the restore instance db deletion
  # except when a DBInstance is not found, so we can still delete the cluster if it exists
  if [[ $RET_CODE != 0 && ! $ERROR =~ "An error occurred (DBInstanceNotFound)" ]]; then
    echo $ERROR
    exit $RET_CODE
  fi
  
  # if restore cluster exists, delete it
  ERROR_CLUSTER=$(aws rds describe-db-clusters --db-cluster-identifier $DB_CLUSTER_IDENTIFIER 2>&1)
  RET_CLUSER_CODE=$?

  DELETE_RET_CLUSTER_CODE=0
  if [[ $RET_CLUSER_CODE == 0 ]]; then
    echo "Deleting restore DB cluster $DB_CLUSTER_IDENTIFIER..."
    ERROR_CLUSTER=$(aws rds delete-db-cluster --db-cluster-identifier $DB_CLUSTER_IDENTIFIER \
      --skip-final-snapshot 2>&1)
    RET_CLUSER_CODE=$?
  fi

  # this if statement is a catch all for any errors with the restore cluster db deletion
  if [[ $RET_CLUSER_CODE != 0 ]]; then
    echo $ERROR_CLUSTER
    exit $RET_CLUSER_CODE
  fi

}

trap cleanup_on_exit EXIT

DB_CLUSTER_IDENTIFIER=$DB_ENGINE-$SERVICE_NAME-auto-restore-cluster
DB_INSTANCE_IDENTIFIER=$DB_ENGINE-$SERVICE_NAME-auto-restore
DUMP=$SERVICE_NAME-$(date +%Y_%m_%d_%H%M%S)
RESTORE_FILE=restore.sql

if [[ ${USE_BACKUPS_ACCOUNT:-true} == "true" ]]
then
  PROFILE_ARG="--profile backup"
else
  PROFILE_ARG=""
fi

mkdir -p ~/.aws

echo "[profile backup]
role_arn=arn:aws:iam::$BACKUP_ACCOUNT_ID:role/$ACCOUNT_GROUP-$ENV-backups
credential_source=Ec2InstanceMetadata" > ~/.aws/config

majorVersion="${DB_ENGINE_VERSION%%.*}"
PSQL_TOOLS_VERSION=$(echo $DB_ENGINE_VERSION | awk -F\. '{print $1"."$2}')

# package name changed 10 on
if [[ $majorVersion -ge 10 ]]; then
  PSQL_TOOLS_VERSION="$majorVersion"
fi

DUMP_FILE=$DUMP.sql

# Enable s3 signature version v4 (for aws bucket server side encryption)
aws configure set s3.signature_version s3v4

# Install the postgres tools matching the engine version
get_time_now
echo "$time_now Postgres dump. installing dependencies..."
if [[ $majorVersion -ge 12 ]]; then
  # amazon-linux-2 doesn't have postgresql packages above V11.
  sudo tee /etc/yum.repos.d/pgdg.repo<<EOF
[pgdg$PSQL_TOOLS_VERSION]
name=PostgreSQL $PSQL_TOOLS_VERSION for RHEL/CentOS 7 - x86_64
baseurl=https://download.postgresql.org/pub/repos/yum/$PSQL_TOOLS_VERSION/redhat/rhel-7-x86_64
enabled=1
gpgcheck=0
EOF
  sudo yum makecache
  sudo yum install -y "postgresql${PSQL_TOOLS_VERSION}"
else
  sudo amazon-linux-extras install -y "postgresql${PSQL_TOOLS_VERSION}" > /dev/null
fi
get_time_now
echo "$time_now ...Done"




# Take the backup
get_time_now
echo "$time_now Taking the backup..."

export PGPASSWORD=$RDS_PASSWORD
if [[ "$majorVersion" == "9" ]]; then
  pg_dump -Fc -h $RDS_ENDPOINT -U $RDS_USERNAME -d $DB_NAME -f $DUMP_FILE -N apgcc
else 
  pg_dumpall --globals-only -U $RDS_USERNAME -h $RDS_ENDPOINT -f $DUMP_FILE
fi
get_time_now
echo "$time_now ...Done"


# Verify the dump file isn't empty before continuing
if [[ ! -s $DUMP_FILE ]]; then
get_time_now
echo "$time_now Error dump file has no data"
exit 2
fi

# Upload it to s3
get_time_now
echo "$time_now Copying dump file to s3 bucket: s3://$BACKUPS_BUCKET/$SERVICE_NAME/rds/"
aws s3 cp $PROFILE_ARG --region $BACKUPS_BUCKET_REGION --only-show-errors $DUMP_FILE s3://$BACKUPS_BUCKET/$SERVICE_NAME/rds/

# Create SQL script
get_time_now
echo "$time_now Expanding & removing COMMENT ON EXTENSION from dump file..."
pg_restore $DUMP_FILE | sed -e '/COMMENT ON EXTENSION/d' \
| sed -e '/CREATE SCHEMA apgcc;/d' \
| sed -e '/ALTER SCHEMA apgcc OWNER TO rdsadmin;/d' > $RESTORE_FILE
get_time_now
echo "$time_now ...Done"

# Verify the restore file isn't empty before continuing
if [[ ! -s $RESTORE_FILE ]]; then
get_time_now
echo "$time_now Error dump file downloaded from s3 has no data"
exit 2
fi


# Create the RDS restore instance
OPTS="--db-name $DB_NAME"

# RDS encryption specific options
if [[ $RDS_INSTANCE_TYPE != "db.t2.micro" ]]; then
  ENCRYPTION="--storage-encrypted --kms-key-id $RDS_KMS_KEY"
else
  ENCRYPTION=""
fi

get_time_now
echo "$time_now Creating DB restore cluster and instance with values:"
echo "$time_now db cluster identifier: $DB_CLUSTER_IDENTIFIER"
echo "$time_now db instance identifier: $DB_INSTANCE_IDENTIFIER"
echo "$time_now db instance class: $RDS_INSTANCE_TYPE"
echo "$time_now engine: $DB_ENGINE"
echo "$time_now username: $RDS_USERNAME"
echo "$time_now storage: $RDS_STORAGE_SIZE"
echo "$time_now engine version: $DB_ENGINE_VERSION"

aws rds create-db-cluster \
    --db-cluster-identifier $DB_CLUSTER_IDENTIFIER \
    --database-name $DB_NAME \
    --engine $DB_ENGINE \
    --engine-version $DB_ENGINE_VERSION \
    --master-username $RDS_USERNAME \
    --master-user-password $RDS_PASSWORD \
    --db-subnet-group-name $SUBNET_GROUP_NAME \
    --vpc-security-group-ids $RDS_SECURITY_GROUP > /dev/null
    
# Wait for the rds endpoint to be available before restoring to it
function rds_cluster_status {
  aws rds describe-db-clusters \
  --db-cluster-identifier $DB_CLUSTER_IDENTIFIER \
  --query 'DBClusters[0].Status' \
  --output text
}

while [[ ! $(rds_cluster_status) == "available" ]]; do
  get_time_now
  echo "$time_now DB server is not online yet ... sleeping"
  sleep 60s
done

get_time_now
echo "$time_now ...DB restore cluster created"

aws rds create-db-instance \
  --db-instance-identifier $DB_INSTANCE_IDENTIFIER \
  --db-cluster-identifier $DB_CLUSTER_IDENTIFIER \
  --db-instance-class $RDS_INSTANCE_TYPE \
  --engine $DB_ENGINE \
  --no-multi-az \
  --engine-version $DB_ENGINE_VERSION \
  --no-publicly-accessible \
  --license-model $DB_LICENSE_MODEL > /dev/null

# Wait for the rds endpoint to be available before restoring to it
function rds_status {
  aws rds describe-db-instances \
  --db-instance-identifier $DB_INSTANCE_IDENTIFIER \
  --query 'DBInstances[0].DBInstanceStatus' \
  --output text
}

while [[ ! $(rds_status) == "available" ]]; do
  get_time_now
  echo "$time_now DB server is not online yet ... sleeping"
  sleep 60s
done

get_time_now
echo "$time_now ...DB restore instance created"

# Our restore DB Address
RESTORE_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier $DB_INSTANCE_IDENTIFIER \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text)

get_time_now
echo "$time_now Restoring Postgres backup..."
psql --set ON_ERROR_STOP=on -h $RESTORE_ENDPOINT -U $RDS_USERNAME -d $DB_NAME < $RESTORE_FILE
get_time_now
echo "$time_now ...Done"


# Check in on success
get_time_now
echo "$time_now Checkin to snitch..."

curl $DMS_URL
get_time_now
echo "$time_now ...Done"

