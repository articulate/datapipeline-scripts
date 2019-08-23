#!/bin/bash

# AWS Data Pipeline RDS backup and verification automation relying on Amazon Linux and S3

# exit immediately if a command exit code is not 0 or a variable is undefined
set -euo pipefail

export AWS_DEFAULT_REGION=$AWS_REGION

# Use trap to print the most recent error message & delete the restore instance
# when the script exits
function cleanup_on_exit {

  echo "Trap EXIT called..."
  echo "If this script exited prematurely, check stderr for the exit error message"

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
  if [[ $RET_CODE != 0 ]]; then
    echo $ERROR
    exit $RET_CODE
  fi

}

trap cleanup_on_exit EXIT

DB_INSTANCE_IDENTIFIER=$DB_ENGINE-$SERVICE_NAME-auto-restore
DUMP=$SERVICE_NAME-$(date +%Y_%m_%d_%H%M%S)
RESTORE_FILE=restore.sql

mkdir -p ~/.aws

echo "[profile backup]
role_arn=arn:aws:iam::$BACKUP_ACCOUNT_ID:role/$ACCOUNT_GROUP-$ENV-backups
credential_source=EcsContainer" > ~/.aws/config

majorVersion="${DB_ENGINE_VERSION%%.*}"
PSQL_TOOLS_VERSION=$(echo $DB_ENGINE_VERSION | awk -F\. '{print $1"."$2}')

# package name changed 10 on
if [[ "$majorVersion" == "10" || "$majorVersion" == "11" ]]; then
PSQL_TOOLS_VERSION="$majorVersion"
fi

DUMP_FILE=$DUMP.sql

# Enable s3 signature version v4 (for aws bucket server side encryption)
aws configure set s3.signature_version s3v4

# Install the postgres tools matching the engine version
echo "Postgres dump. installing dependencies..."

sudo amazon-linux-extras install -y postgresql$PSQL_TOOLS_VERSION > /dev/null
# echo "deb http://apt.postgresql.org/pub/repos/apt/ stretch-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list
# wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
# sudo apt-get update
# sudo apt-get -y install postgresql-client-$PSQL_TOOLS_VERSION > /dev/null
echo "...Done"

# Take the backup
echo "Taking the backup..."
export PGPASSWORD=$RDS_PASSWORD
pg_dump -Fc -h $RDS_ENDPOINT -U $RDS_USERNAME -d $DB_NAME -f $DUMP_FILE
echo "...Done"

# Verify the dump file isn't empty before continuing
if [[ ! -s $DUMP_FILE ]]; then
echo "Error dump file has no data"
exit 2
fi

# Upload it to s3
echo "Copying dump file to s3 bucket: s3://$BACKUPS_BUCKET/$SERVICE_NAME/rds/"
aws s3 cp --region $BACKUPS_BUCKET_REGION --only-show-errors $DUMP_FILE s3://$BACKUPS_BUCKET/$SERVICE_NAME/rds/

# Create SQL script
echo "Expanding & removing COMMENT ON EXTENSION from dump file..."
pg_restore $DUMP_FILE | sed -e '/COMMENT ON EXTENSION/d' \
| sed -e '/CREATE SCHEMA apgcc;/d' \
| sed -e '/ALTER SCHEMA apgcc OWNER TO rdsadmin;/d' > $RESTORE_FILE
echo "...Done"

# Verify the restore file isn't empty before continuing
if [[ ! -s $RESTORE_FILE ]]; then
echo "Error dump file downloaded from s3 has no data"
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

echo "Creating DB restore instance with values:"
echo "db instance identifier: $DB_INSTANCE_IDENTIFIER"
echo "db instance class: $RDS_INSTANCE_TYPE"
echo "engine: $DB_ENGINE"
echo "username: $RDS_USERNAME"
echo "storage: $RDS_STORAGE_SIZE"
echo "engine version: $DB_ENGINE_VERSION"

aws rds create-db-instance $OPTS $ENCRYPTION \
  --db-instance-identifier $DB_INSTANCE_IDENTIFIER \
  --db-instance-class $RDS_INSTANCE_TYPE \
  --engine $DB_ENGINE \
  --master-username $RDS_USERNAME \
  --master-user-password $RDS_PASSWORD \
  --vpc-security-group-ids $RDS_SECURITY_GROUP \
  --no-multi-az \
  --storage-type gp2 \
  --allocated-storage $RDS_STORAGE_SIZE \
  --engine-version $DB_ENGINE_VERSION \
  --no-publicly-accessible \
  --db-subnet-group $SUBNET_GROUP_NAME \
  --backup-retention-period 0 \
  --license-model $DB_LICENSE_MODEL > /dev/null

# Wait for the rds endpoint to be available before restoring to it
function rds_status {
  aws rds describe-db-instances \
  --db-instance-identifier $DB_INSTANCE_IDENTIFIER \
  --query 'DBInstances[0].DBInstanceStatus' \
  --output text
}

while [[ ! $(rds_status) == "available" ]]; do
  echo "DB server is not online yet ... sleeping"
  sleep 60s
done

echo "...DB restore instance created"

# Our restore DB Address
RESTORE_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier $DB_INSTANCE_IDENTIFIER \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text)

echo "Restoring Postgres backup..."
psql --set ON_ERROR_STOP=on -h $RESTORE_ENDPOINT -U $RDS_USERNAME -d $DB_NAME < $RESTORE_FILE
echo "...Done"


# Check in on success
echo "Checkin to snitch..."
curl $DMS_URL
echo "...Done"
