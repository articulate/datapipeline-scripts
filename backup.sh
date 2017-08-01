#!/bin/bash

# AWS Data Pipeline RDS backup and verification automation relying on Amazon Linux and S3
export AWS_DEFAULT_REGION=us-east-1

DB_INSTANCE_IDENTIFIER=$DB_ENGINE-$SERVICE_NAME-auto-restore
RESTORE_FILE=restore.sql

if [ "$DB_ENGINE" == "sqlserver-se" ]; then
  DUMP_FILE=$SERVICE_NAME-$(date +%Y_%m_%d_%H%M%S).db
  sudo yum install docker -y
  sudo service docker start

  sudo docker run -it microsoft/mssql-server-linux /opt/mssql-tools/bin/sqlcmd -S $RDS_ENDPOINT -U $RDS_USERNAME -P $RDS_PASSWORD -Q "exec msdb.dbo.rds_backup_database @source_db_name='PROD', @s3_arn_to_backup_to='arn:aws:s3:::$BACKUP_BUCKET/$SERVICE_NAME/$DUMP_FILE', @overwrite_S3_backup_file=1;"
else
  PSQL_TOOLS_VERSION=$(echo $DB_ENGINE_VERSION | awk -F\. '{print $1$2}')
  DUMP_FILE=$SERVICE_NAME-$(date +%Y_%m_%d_%H%M%S).sql

  # Install the postgres tools matching the engine version
  sudo yum install -y postgresql$PSQL_TOOLS_VERSION

  # Take the backup
  export PGPASSWORD=$RDS_PASSWORD
  pg_dump -Fc -h $RDS_ENDPOINT -U $RDS_USERNAME -d $DB_NAME > $DUMP_FILE

  # Verify the dump file isn't empty before continuing
  if [ ! -s $DUMP_FILE ]; then
    exit 2
  fi
  
  # Upload it to s3
  aws s3 cp $DUMP_FILE s3://$BACKUP_BUCKET/$SERVICE_NAME/
  
  # Delete the file
  rm $DUMP_FILE

  aws s3 cp s3://$BACKUP_BUCKET/$SERVICE_NAME/$DUMP_FILE .

  # Create SQL script
  pg_restore $DUMP_FILE | sed -e '/COMMENT ON EXTENSION/d' > $RESTORE_FILE
  
  # Verify the restore file isn't empty before continuing
  if [ ! -s $RESTORE_FILE ]; then
    exit 2
  fi
fi

# Create the RDS restore instance
aws rds create-db-instance --db-name $DB_NAME --db-instance-identifier $DB_INSTANCE_IDENTIFIER --db-instance-class $RDS_INSTANCE_TYPE \
  --engine $DB_ENGINE --master-username $RDS_USERNAME --master-user-password $RDS_PASSWORD --vpc-security-group-ids $RDS_SECURITY_GROUP \
  --no-multi-az --storage-type gp2 --allocated-storage $RDS_STORAGE_SIZE --engine-version $DB_ENGINE_VERSION --no-publicly-accessible \
  --db-subnet-group $SUBNET_GROUP_NAME --backup-retention-period 0

# Wait for the rds endpoint to be available before setting it
while [[ ! $(aws rds describe-db-instances --db-instance-identifier $DB_INSTANCE_IDENTIFIER --output=text | awk '/ENDPOINT/ {print $2}') =~ "rds.amazonaws.com" ]]; do
  sleep 30s
done

RESTORE_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier $DB_INSTANCE_IDENTIFIER --output=text | awk '/ENDPOINT/ {print $2}')

# Restore the data
if [ "$DATABASE_TYPE" == "sqlserver-se" ]; then
  sudo docker run -it microsoft/mssql-server-linux /opt/mssql-tools/bin/sqlcmd -S $RDS_ENDPOINT -U $RDS_USERNAME -P $RDS_PASSWORD -Q "exec msdb.dbo.rds_restore_database @restore_db_name='PROD', @s3_arn_to_restore_from='arn:aws:s3:::$BACKUP_BUCKET/$SERVICE_NAME/$DUMP_FILE';"
else
  psql --set ON_ERROR_STOP=on -h $RESTORE_ENDPOINT -U $RDS_USERNAME -d $DB_NAME < $RESTORE_FILE
fi

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
  exit 1
fi
