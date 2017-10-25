#!/bin/bash

# AWS Data Pipeline RDS backup and verification automation relying on Amazon Linux and S3

# exit immediately if a command exit code is not 0 or a variable is undefined
set -euo pipefail

export AWS_DEFAULT_REGION=us-east-1

# Use trap to print the most recent error message & delete the restore instance
# when the script exits
function cleanup_on_exit {

  echo "Trap EXIT called..."
  echo "If this script exited prematurely, check stderr for the exit error message"

  # if restore instance exists, delete it
  ERROR=$(aws rds describe-db-instances --db-instance-identifier $DB_INSTANCE_IDENTIFIER 2>&1)
  RET_CODE=$?

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

SQLCMD=/opt/mssql-tools/bin/sqlcmd-13.0.1.0
DB_INSTANCE_IDENTIFIER=$DB_ENGINE-$SERVICE_NAME-auto-restore
DUMP=$SERVICE_NAME-$(date +%Y_%m_%d_%H%M%S)
RESTORE_FILE=restore.sql

if [[ $DB_ENGINE == "sqlserver-se" ]]; then

  DUMP_FILE=$DUMP.db

  # Install sqlcmd microsoft client libs & cvskit
  echo "Sqlserver dump. installing dependencies..."
  sudo pip install --upgrade six > /dev/null
  sudo pip install csvkit > /dev/null
  curl -s https://packages.microsoft.com/keys/microsoft.asc | tee /tmp/microsoft.asc > /dev/null
  sudo rpm --quiet --import /tmp/microsoft.asc
  curl -s https://packages.microsoft.com/config/rhel/6/prod.repo \
    | sudo tee /etc/yum.repos.d/msprod.repo > /dev/null
  sudo ACCEPT_EULA=Y yum -y install msodbcsql-13.0.1.0-1 mssql-tools-14.0.2.0-1 > /dev/null
  echo "...Done"

  # Run backup and capture the backup task status
  echo "Start the Mssql backup..."
  TASK_OUTPUT=$($SQLCMD -S $RDS_ENDPOINT -U $RDS_USERNAME -P $RDS_PASSWORD -Q \
    "exec msdb.dbo.rds_backup_database @source_db_name='$DB_NAME', \
    @s3_arn_to_backup_to='arn:aws:s3:::$BACKUP_BUCKET/$SERVICE_NAME/$DUMP_FILE', \
    @overwrite_S3_backup_file=1;" -W -s ',' -k 1)

  # Get the task id of the backup task status
  echo "Get the task id..."
  TASK_ID=$(echo "$TASK_OUTPUT" | csvcut -c "task_id" | grep "Task Id" | grep -oE "[^:][0-9]$")
  if [[ -n $TASK_ID ]]; then
    echo "Started mssql backup with task id: $TASK_ID"
  else
    echo "Error getting task id. Aborting."
    echo $TASK_ID
    exit 1
  fi

  # Wait until backup status is SUCCESS before continuing
  function backup_task_status {
    $SQLCMD -S $RDS_ENDPOINT -U $RDS_USERNAME -P $RDS_PASSWORD -Q \
    "exec msdb.dbo.rds_task_status @task_id='$TASK_ID'" -W -s "," -k 1 \
    | csvcut -c "lifecycle" | tail -1
  }

  BACKUP_TASK_STATUS=$(backup_task_status)
  while [[ $BACKUP_TASK_STATUS =~ (^CREATED$|^IN_PROGRESS$) ]]; do
    echo "Backup status is $BACKUP_TASK_STATUS..."
    sleep 30s
    BACKUP_TASK_STATUS=$(backup_task_status)
  done

  if [[ "$BACKUP_TASK_STATUS" == "SUCCESS" ]]; then
    echo "...Backup task complete, restoring to temp db."
  else
    echo "...Backup task errored."
    echo "Task status: $BACKUP_TASK_STATUS"
    exit 1
  fi

else # Our default db is Postgres

  PSQL_TOOLS_VERSION=$(echo $DB_ENGINE_VERSION | awk -F\. '{print $1$2}')
  DUMP_FILE=$DUMP.sql
  SSE="--sse aws:kms --sse-kms-key-id $KMS_KEY"

  # Enable s3 signature version v4 (for aws bucket server side encryption)
  aws configure set s3.signature_version s3v4

  # Install the postgres tools matching the engine version
  echo "Postgres dump. installing dependencies..."
  sudo yum install -y postgresql$PSQL_TOOLS_VERSION > /dev/null
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
  echo "Copying dump file to s3..."
  aws s3 cp $SSE $DUMP_FILE s3://$BACKUP_BUCKET/$SERVICE_NAME/

  # Delete the file
  rm -f $DUMP_FILE
  echo "...Done"

  # Copy dump from s3 to restore to temp db
  echo "Downloading dump file from s3..."
  aws s3 cp $SSE s3://$BACKUP_BUCKET/$SERVICE_NAME/$DUMP_FILE .
  echo "...Done"

  # Create SQL script
  echo "Expanding & removing COMMENT ON EXTENSION from dump file..."
  pg_restore $DUMP_FILE | sed -e '/COMMENT ON EXTENSION/d' > $RESTORE_FILE
  echo "...Done"

  # Verify the restore file isn't empty before continuing
  if [[ ! -s $RESTORE_FILE ]]; then
    echo "Error dump file downloaded from s3 has no data"
    exit 2
  fi

fi

# Create the RDS restore instance

# Sql engine specific options
if [[ $DB_ENGINE == "sqlserver-se" ]]; then
  OPTS="--option-group-name $DB_OPTION_GROUP_NAME"
else
  OPTS="--db-name $DB_NAME"
fi

echo "Create DB restore instance..."

aws rds create-db-instance $OPTS \
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
  sleep 30s
done

echo "...DB restore instance created"

# Our restore DB Address
RESTORE_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier $DB_INSTANCE_IDENTIFIER \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text)

if [[ $DB_ENGINE == "sqlserver-se" ]]; then
  # Wait for option group to be insync
  function rds_option_group {
    aws rds describe-db-instances \
      --db-instance-identifier $DB_INSTANCE_IDENTIFIER \
      --query 'DBInstances[0].OptionGroupMemberships[0].Status' \
      --output text
  }

  while [[ ! $(rds_option_group) == "in-sync" ]]; do
    echo "Option group membership not in sync ... sleeping"
    sleep 30s
  done

  # Run restore and capture the task status
  echo "Start the Mssql restore..."
  RES_TASK_OUTPUT=$($SQLCMD -S $RESTORE_ENDPOINT -U $RDS_USERNAME -P $RDS_PASSWORD -Q \
    "exec msdb.dbo.rds_restore_database @restore_db_name='$DB_NAME', \
    @s3_arn_to_restore_from='arn:aws:s3:::$BACKUP_BUCKET/$SERVICE_NAME/$DUMP_FILE';" \
    -W -s ',' -k 1)

  # Get the task id of the restore task status
  echo "Get the task id..."
  RES_TASK_ID=$(echo "$RES_TASK_OUTPUT" | csvcut -c "task_id" | grep "Task Id" | grep -oE "[^:][0-9]$")
  if [[ -n $RES_TASK_ID ]]; then
    echo "Started mssql restore with task id: $RES_TASK_ID"
  else
    echo "Error getting task id. Aborting."
    exit 1
  fi

  # Wait until restore status is SUCCESS before continuing
  function restore_task_status {
    $SQLCMD -S $RESTORE_ENDPOINT -U $RDS_USERNAME -P $RDS_PASSWORD -Q \
    "exec msdb.dbo.rds_task_status @task_id='$RES_TASK_ID'" -W -s "," -k 1 \
    | csvcut -c "lifecycle" | tail -1
  }

  RESTORE_TASK_STATUS=$(restore_task_status)
  while [[ $RESTORE_TASK_STATUS =~ (^CREATED$|^IN_PROGRESS$) ]]; do
    echo "Status is still $RESTORE_TASK_STATUS..."
    sleep 30s
    RESTORE_TASK_STATUS=$(restore_task_status)
  done

  if [[ $RESTORE_TASK_STATUS == "SUCCESS" ]]; then
    echo "...Restore task complete"
  else
    echo "Restore task errored..."
    echo "Task status: $RESTORE_TASK_STATUS"
    exit 1
  fi

else # Restore Postgres db

  echo "Restoring Postgres backup..."
  psql --set ON_ERROR_STOP=on -h $RESTORE_ENDPOINT -U $RDS_USERNAME -d $DB_NAME < $RESTORE_FILE
  echo "...Done"

fi

# Give full control to the root user in our AWS Backup Account
echo "Grant full control of dump file to AWS Backup Account..."
aws s3api put-object-acl --bucket articulate-db-backups --key $SERVICE_NAME/$DUMP_FILE \
  --grant-full-control emailaddress=$AWS_EMAIL_ADDRESS
echo "...Done"

# Check in on success
echo "Checkin to snitch..."
curl $CHECK_IN_URL
echo "...Done"
