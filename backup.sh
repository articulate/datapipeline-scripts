#!/bin/bash

# AWS Data Pipeline RDS backup and verification automation relying on Amazon Linux and S3
export AWS_DEFAULT_REGION=us-east-1

DB_INSTANCE_IDENTIFIER=$DB_ENGINE-$SERVICE_NAME-auto-restore
RESTORE_FILE=restore.sql
SUCCESS=0

if [ "$DB_ENGINE" == "sqlserver-se" ]; then
  DUMP_FILE=$SERVICE_NAME-$(date +%Y_%m_%d_%H%M%S).db
  sudo pip install --upgrade six
  sudo pip install csvkit
  sudo yum install docker -y
  sudo service docker start
  sleep 30

  TASK_OUTPUT=$(sudo docker run -t microsoft/mssql-server-linux /opt/mssql-tools/bin/sqlcmd -S $RDS_ENDPOINT -U $RDS_USERNAME -P $RDS_PASSWORD -Q "exec msdb.dbo.rds_backup_database @source_db_name='$DB_NAME', @s3_arn_to_backup_to='arn:aws:s3:::$BACKUP_BUCKET/$SERVICE_NAME/$DUMP_FILE', @overwrite_S3_backup_file=1;" -W -s ',' -k 1)
  TASK_ID=$(echo "$TASK_OUTPUT" | head -3 | csvcut -c 'task_id' | tail -1)

  if [[ "$?" == "0" && -n "$TASK_ID" ]]; then
    echo "Started mssql backup with TASK_ID: $TASK_ID"
  else
    echo "MSSQL task could not be started"
    echo "$TASK_OUTPUT"
    exit 1
  fi
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
if [ "$DB_ENGINE" == "sqlserver-se" ]; then
  OPTS="--option-group-name $DB_OPTION_GROUP_NAME"
else
  OPTS="--db-name $DB_NAME"
fi
aws rds create-db-instance $OPTS --db-instance-identifier $DB_INSTANCE_IDENTIFIER --db-instance-class $RDS_INSTANCE_TYPE \
  --engine $DB_ENGINE --master-username $RDS_USERNAME --master-user-password $RDS_PASSWORD --vpc-security-group-ids $RDS_SECURITY_GROUP \
  --no-multi-az --storage-type gp2 --allocated-storage $RDS_STORAGE_SIZE --engine-version $DB_ENGINE_VERSION --no-publicly-accessible \
  --db-subnet-group $SUBNET_GROUP_NAME --backup-retention-period 0 --license-model $DB_LICENSE_MODEL

SUCCESS=$?
echo "Create DB exited with ${SUCCESS}"

if [ "$SUCCESS" == "0" ]; then
  # Wait for the rds endpoint to be available before setting it
  while [[ ! $(aws rds describe-db-instances --db-instance-identifier $DB_INSTANCE_IDENTIFIER --query 'DBInstances[0].DBInstanceStatus' --output text) = "available" ]]; do
    echo "DB server is not online yet .. sleeping"
    sleep 30s
  done

  RESTORE_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier $DB_INSTANCE_IDENTIFIER --query 'DBInstances[0].Endpoint.Address' --output text)

  # Restore the data
  if [ "$DB_ENGINE" == "sqlserver-se" ]; then
    # Wait for option group to be insync
    while [[ ! $(aws rds describe-db-instances --db-instance-identifier $DB_INSTANCE_IDENTIFIER --query 'DBInstances[0].OptionGroupMemberships[0].Status' --output text) = "in-sync" ]]; do
      echo "Option group membership not in sync .. sleeping"
      sleep 30s
    done

    BACKUP_TASK_STATUS=$(sudo docker run -t microsoft/mssql-server-linux /opt/mssql-tools/bin/sqlcmd -S $RDS_ENDPOINT -U $RDS_USERNAME -P $RDS_PASSWORD -Q "exec msdb.dbo.rds_task_status @task_id='$TASK_ID'" -W -s "," -k 1 | csvcut -c "lifecycle" | tail -1)
    while [[ "$BACKUP_TASK_STATUS" == "CREATED" || $BACKUP_TASK_STATUS = "IN_PROGRESS" ]]; do
      echo "Status is still $BACKUP_TASK_STATUS"
      sleep 30s
      BACKUP_TASK_STATUS=$(sudo docker run -t microsoft/mssql-server-linux /opt/mssql-tools/bin/sqlcmd -S $RDS_ENDPOINT -U $RDS_USERNAME -P $RDS_PASSWORD -Q "exec msdb.dbo.rds_task_status @task_id='$TASK_ID'" -W -s "," -k 1 | csvcut -c "lifecycle" | tail -1)
    done
    if [[ "$BACKUP_TASK_STATUS" == "SUCCESS" ]]; then
      echo "Backup task complete, restoring to temp db."
      RESTORE_TASK_ID=$(sudo docker run -t microsoft/mssql-server-linux /opt/mssql-tools/bin/sqlcmd -S $RESTORE_ENDPOINT -U $RDS_USERNAME -P $RDS_PASSWORD -Q "exec msdb.dbo.rds_restore_database @restore_db_name='$DB_NAME', @s3_arn_to_restore_from='arn:aws:s3:::$BACKUP_BUCKET/$SERVICE_NAME/$DUMP_FILE';" -W -s "," -k 1 |head -3 | csvcut -c "task_id" | tail -1)
    else
      echo "Backup task errored."
      echo "Task status: $BACKUP_TASK_STATUS"
      SUCCESS=1
    fi

    if [ "$SUCCESS" == "0" ]; then
      RESTORE_TASK_STATUS=$(sudo docker run -t microsoft/mssql-server-linux /opt/mssql-tools/bin/sqlcmd -S $RESTORE_ENDPOINT -U $RDS_USERNAME -P $RDS_PASSWORD -Q "exec msdb.dbo.rds_task_status @task_id='$RESTORE_TASK_ID'" -W -s "," -k 1 | csvcut -c "lifecycle" | tail -1)
      while [[ "$RESTORE_TASK_STATUS" == "CREATED" || $RESTORE_TASK_STATUS = "IN_PROGRESS" ]]; do
        echo "Status is still $RESTORE_TASK_STATUS"
        sleep 30s
        RESTORE_TASK_STATUS=$(sudo docker run -t microsoft/mssql-server-linux /opt/mssql-tools/bin/sqlcmd -S $RESTORE_ENDPOINT -U $RDS_USERNAME -P $RDS_PASSWORD -Q "exec msdb.dbo.rds_task_status @task_id='$RESTORE_TASK_ID'" -W -s "," -k 1 | csvcut -c "lifecycle" | tail -1)
      done

      if [[ $RESTORE_TASK_STATUS = "SUCCESS" ]]; then
        echo "Restore task complete."
      else
        echo "Restore task errored."
        echo "Task status: $RESTORE_TASK_STATUS"
        SUCCESS=1
      fi
    fi
  else
    psql --set ON_ERROR_STOP=on -h $RESTORE_ENDPOINT -U $RDS_USERNAME -d $DB_NAME < $RESTORE_FILE
    SUCCESS=$?
  fi
else
  echo "DB server failed to launch"
fi

if [ "$SUCCESS" == "0" ]; then
  # give full control to the root user in our AWS Backup Account
  aws s3api put-object-acl --bucket articulate-db-backups --key $SERVICE_NAME/$DUMP_FILE --grant-full-control emailaddress=$AWS_EMAIL_ADDRESS
  # Check in on success
  curl $CHECK_IN_URL
fi

aws rds delete-db-instance --db-instance-identifier $DB_INSTANCE_IDENTIFIER --skip-final-snapshot

exit $SUCCESS
