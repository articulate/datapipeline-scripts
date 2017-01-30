#!/bin/bash

# Script designed to work with AWS Data Pipeline
# which automates backing up and testing psql backups

export AWS_DEFAULT_REGION=us-east-1
export PGPASSWORD=$RDS_PASSWORD
export PSQL_TOOLS_VERSION=$(echo $PSQL_VERSION | awk -F\. '{print $1$2}')

dump_file=$APP_NAME-$(date +%Y_%m_%d_%H%M%S).sql

# Install the postgres tools matching the engine version
sudo yum install -y postgresql$PSQL_TOOLS_VERSION

# Take the backup
pg_dump -Fc -h $RDS_ENDPOINT -U $RDS_USERNAME -d $DATABASE_NAME > $dump_file

# Verify the dump file isn't empty before continuing
if [ ! -s $dump_file ]
then
  exit 2
fi

# Upload it to s3
aws s3 cp $dump_file s3://$S3_BUCKET/$APP_NAME/

# Delete the file
rm $dump_file

# Grab it from s3 to make sure it's intact
aws s3 cp s3://$S3_BUCKET/$APP_NAME/$dump_file .

# Create SQL script and remove extension comments
pg_restore $dump_file > restore.sql
sed -i '/COMMENT ON EXTENSION/d' restore.sql

# Verify the restore file isn't empty before continuing
if [ ! -s restore.sql ]
then
  exit 2
fi

# Create the RDS restore instance
aws rds create-db-instance --db-name $DATABASE_NAME --db-instance-identifier postgres-$APP_NAME-auto-restore --db-instance-class $INSTANCE_SIZE --engine postgres --master-username $RDS_USERNAME --master-user-password $RDS_PASSWORD --vpc-security-group-ids $SECURITY_GROUP_ID --no-multi-az --storage-type gp2 --allocated-storage $STORAGE_SIZE --engine-version $PSQL_VERSION --no-publicly-accessible --db-subnet-group $SUBNET_GROUP_NAME --backup-retention-period 0

# Wait for the rds endpoint to be available before setting it
while [[ ! $(aws rds describe-db-instances --db-instance-identifier postgres-$APP_NAME-auto-restore --output=text | awk '/ENDPOINT/ {print $2}') =~ "rds.amazonaws.com" ]]
do
  sleep 30s
done

restore_endpoint=$(aws rds describe-db-instances --db-instance-identifier postgres-$APP_NAME-auto-restore --output=text | awk '/ENDPOINT/ {print $2}')

# Restore the data
psql --set ON_ERROR_STOP=on -h $restore_endpoint -U $RDS_USERNAME -d $DATABASE_NAME < restore.sql

if [ "$?" == "0" ]
then
  aws rds delete-db-instance --db-instance-identifier postgres-$APP_NAME-auto-restore --skip-final-snapshot
  if [ "$?" == "0" ]
  then
    # give full control to the root user in our AWS Backup Account
    aws s3api put-object-acl --bucket articulate-db-backups --key $APP_NAME/$dump_file --grant-full-control emailaddress=$EMAIL_ADDRESS
    # Notify DMS if successful
    curl $DMS_URL
  fi
else
  aws rds delete-db-instance --db-instance-identifier postgres-$APP_NAME-auto-restore --skip-final-snapshot
fi
