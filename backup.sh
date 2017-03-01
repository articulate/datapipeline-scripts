#!/bin/bash

# AWS Data Pipeline RDS backup and verification automation relying on Amazon Linux and S3

export AWS_DEFAULT_REGION=us-east-1
export PGPASSWORD=$RDS_PASSWORD

DB_INSTANCE_IDENTIFIER=$DB_ENGINE-$DB_NAME-auto-restore
DUMP_FILE=$SERVICE_NAME-$(date +%Y_%m_%d_%H%M%S).sql
PSQL_TOOLS_VERSION=$(echo $PSQL_VERSION | awk -F\. '{print $1$2}')
RESTORE_FILE=restore.sql

# Install the postgres tools matching the engine version
sudo yum install -y postgresql$PSQL_TOOLS_VERSION

# Take the backup
pg_dump -Fc -h $RDS_ENDPOINT -U $RDS_USERNAME -d $DB_NAME > $DUMP_FILE

# Verify the dump file isn't empty before continuing
if [ ! -s $DUMP_FILE ]; then
  exit 2
fi

# Upload it to s3
aws s3 cp $DUMP_FILE s3://$S3_BUCKET/$SERVICE_NAME/

# Delete the file
rm $DUMP_FILE

# Grab it from s3 to make sure it's intact
aws s3 cp s3://$S3_BUCKET/$SERVICE_NAME/$DUMP_FILE .

# Create SQL script and remove extension comments
pg_restore $DUMP_FILE > $RESTORE_FILE
sed -i '/COMMENT ON EXTENSION/d' $RESTORE_FILE

# Verify the restore file isn't empty before continuing
if [ ! -s $RESTORE_FILE ]; then
  exit 2
fi

# Create the RDS restore instance
aws rds create-db-instance --db-name $DB_NAME --db-instance-identifier $DB_INSTANCE_IDENTIFIER --db-instance-class $RDS_INSTANCE_TYPE \
  --engine $DB_ENGINE --master-username $RDS_USERNAME --master-user-password $RDS_PASSWORD --vpc-security-group-ids $RDS_SECURITY_GROUP \
  --no-multi-az --storage-type gp2 --allocated-storage $STORAGE_SIZE --engine-version $DB_ENGINE_VERSION --no-publicly-accessible \
  --db-subnet-group $SUBNET_GROUP_NAME --backup-retention-period 0

# Wait for the rds endpoint to be available before setting it
while [[ ! $(aws rds describe-db-instances --db-instance-identifier $DB_INSTANCE_IDENTIFIER --output=text | awk '/ENDPOINT/ {print $2}') =~ "rds.amazonaws.com" ]]; do
  sleep 30s
done

RESTORE_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier $DB_INSTANCE_IDENTIFIER --output=text | awk '/ENDPOINT/ {print $2}')

# Restore the data
psql --set ON_ERROR_STOP=on -h $RESTORE_ENDPOINT -U $RDS_USERNAME -d $DB_NAME < $RESTORE_FILE

if [ "$?" == "0" ]; then
  aws rds delete-db-instance --db-instance-identifier $DB_INSTANCE_IDENTIFIER --skip-final-snapshot
  if [ "$?" == "0" ]; then
    # give full control to the root user in our AWS Backup Account
    aws s3api put-object-acl --bucket articulate-db-backups --key $SERVICE_NAME/$DUMP_FILE --grant-full-control emailaddress=$AWS_EMAIL_ADDRESS
    # Check in on success
    curl $CHECK_IN_URL
  fi
else
  aws rds delete-db-instance --db-instance-identifier $DB_INSTANCE_IDENTIFIER --skip-final-snapshot
fi
