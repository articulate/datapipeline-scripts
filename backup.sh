#!/bin/bash

# AWS Data Pipeline RDS backup and verification automation relying on Amazon Linux and S3

# exit immediately if a command exit code is not 0 or a variable is undefined
set -euo pipefail

export AWS_DEFAULT_REGION=us-east-1

# Use trap to print the most recent error message & delete the restore instance
# when the script exits

function get_time_now {
  time_now=$(date --utc +%FT%T.%3NZ)
}

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
  if [[ $RET_CODE != 0 ]]; then
    echo $ERROR
    exit $RET_CODE
  fi

}

trap cleanup_on_exit EXIT

# call sqlcmd with retries/backoff so it doesn't fail right away after just one attempt
function sqlcmd_with_backoff {
  local max_attempts=${ATTEMPTS-9}
  local timeout=${TIMEOUT-2}
  local attempt=0

  while [[ $attempt < $max_attempts ]]
  do
    local exitCode=0
    MSG=$("$@" 2>&1)

    if [[ $MSG =~ "Sqlcmd: Error" ]]
    then
      exitCode=1
    fi

    if [[ $exitCode == 0 ]]
    then
      echo "$MSG"
      break
    fi

    echo "Failure! Retrying in $timeout seconds.." 1>&2
    sleep $timeout
    attempt=$(( attempt + 1 ))
    timeout=$(( timeout * 2 ))
  done

  if [[ $exitCode != 0 ]]
  then
    echo "$MSG" 1>&2
  fi

  return $exitCode
}

SQLCMD=/opt/mssql-tools/bin/sqlcmd-13.0.1.0
DB_INSTANCE_IDENTIFIER=$DB_ENGINE-$SERVICE_NAME-auto-restore
DUMP=$SERVICE_NAME-$(date +%Y_%m_%d_%H%M%S)
RESTORE_FILE=restore.sql
SSE="--sse aws:kms --sse-kms-key-id $KMS_KEY"

if [[ ${USE_BACKUPS_ACCOUNT:-true} == "true" ]]
then
  PROFILE_ARG="--profile backup"
else
  PROFILE_ARG=""
fi

mkdir -p ~/.aws

echo "[profile backup]
role_arn=arn:aws:iam::280225230962:role/$BACKUP_ENV-backup
credential_source=Ec2InstanceMetadata" > ~/.aws/config


########################################
###                                  ###
###   Steps to do the backup below   ###
###                                  ###
########################################


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
  TASK_OUTPUT=$(sqlcmd_with_backoff $SQLCMD -S $RDS_ENDPOINT -U $RDS_USERNAME -P $RDS_PASSWORD -Q \
    "exec msdb.dbo.rds_backup_database @source_db_name='$DB_NAME', \
    @s3_arn_to_backup_to='arn:aws:s3:::$BACKUP_TEMP_BUCKET/$DUMP_FILE', \
    @overwrite_S3_backup_file=1;" -W -s ',' -k 1)

  # Error (to stderr) if a backup task is already running
  if [[ $(echo $TASK_OUTPUT | grep "A task has already been issued for database") ]]; then
    (>&2 echo $TASK_OUTPUT)
    exit 1
  fi

  # Get the task id of the backup task status
  echo "Get the task id..."
  TASK_ID=$(echo "$TASK_OUTPUT" | csvcut -c "task_id" | grep "Task Id" | grep -o "[0-9]*")
  if [[ -n $TASK_ID ]]; then
    echo "Started mssql backup with task id: $TASK_ID"
  else
    echo "Error getting task id. Aborting."
    echo $TASK_ID
    exit 1
  fi

  # Wait until backup status is SUCCESS before continuing
  function backup_task_status {
    sqlcmd_with_backoff $SQLCMD -S $RDS_ENDPOINT -U $RDS_USERNAME -P $RDS_PASSWORD -Q \
    "exec msdb.dbo.rds_task_status @task_id='$TASK_ID'" -W -s "," -k 1 \
    | csvcut -c "lifecycle" | tail -1
  }

  BACKUP_TASK_STATUS=$(backup_task_status)
  echo "Backup status is $BACKUP_TASK_STATUS..."
  TEMP_BACKUP_STATUS=$BACKUP_TASK_STATUS
  while [[ $BACKUP_TASK_STATUS =~ (^CREATED$|^IN_PROGRESS$) ]]; do
    if [[ $BACKUP_TASK_STATUS != $TEMP_BACKUP_STATUS ]]; then
      echo "Backup status is $BACKUP_TASK_STATUS..."
    fi
    TEMP_BACKUP_STATUS=$BACKUP_TASK_STATUS
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

  # Transfer dump file to the permanent backup bucket
  echo "Copying dump file to s3 bucket: s3://$BACKUP_BUCKET/$BACKUP_ENV/$SERVICE_NAME/"
  aws s3 cp $PROFILE_ARG $SSE --only-show-errors s3://$BACKUP_TEMP_BUCKET/$DUMP_FILE s3://$BACKUP_BUCKET/$BACKUP_ENV/$SERVICE_NAME/

else # Our default db is Postgres
  majorVersion="${DB_ENGINE_VERSION%%.*}"
  PSQL_TOOLS_VERSION=$(echo $DB_ENGINE_VERSION | awk -F\. '{print $1$2}')

  # Install the postgres tools matching the engine version
  get_time_now
  echo "$time_now Postgres dump. Installing dependencies..."

  if [[ $majorVersion -ge 10 ]]; then
    # we use the amazon-linux-2 AMI for postgres versions 10 and 11
    # so install the postgresql package using amazon-linux-extras
    sudo amazon-linux-extras install -y postgresql$majorVersion > /dev/null
  else
    sudo yum install -y postgresql$PSQL_TOOLS_VERSION > /dev/null
  fi

  get_time_now
  echo "$time_now ...Done installing dependencies."

  DUMP_FILE=$DUMP.sql

  # Enable s3 signature version v4 (for aws bucket server side encryption)
  aws configure set s3.signature_version s3v4

  # Take the backup
  get_time_now
  echo "$time_now Taking the backup..."
  export PGPASSWORD=$RDS_PASSWORD
  pg_dump -Fc -h $RDS_ENDPOINT -U $RDS_USERNAME -d $DB_NAME -f $DUMP_FILE -N apgcc
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
  echo "$time_now Copying dump file to s3 bucket: s3://$BACKUP_BUCKET/$BACKUP_ENV/$SERVICE_NAME/"
  aws s3 cp $PROFILE_ARG $SSE --only-show-errors $DUMP_FILE s3://$BACKUP_BUCKET/$BACKUP_ENV/$SERVICE_NAME/
fi

######################################################
###                                                ###
###   Steps to create restore RDS instance below   ###
###                                                ###
######################################################


# Sql engine specific options
if [[ $DB_ENGINE == "sqlserver-se" ]]; then
  OPTS="--option-group-name $DB_OPTION_GROUP_NAME"
else
  OPTS="--db-name $DB_NAME"
fi

# RDS encryption specific options
if [[ $RDS_INSTANCE_TYPE != "db.t2.micro" ]]; then
  ENCRYPTION="--storage-encrypted --kms-key-id $RDS_KMS_KEY"
else
  ENCRYPTION=""
fi

get_time_now
echo "$time_now Creating DB restore instance with values:"
echo "$time_now db instance identifier: $DB_INSTANCE_IDENTIFIER"
echo "$time_now db instance class: $RDS_INSTANCE_TYPE"
echo "$time_now engine: $DB_ENGINE"
echo "$time_now username: $RDS_USERNAME"
echo "$time_now storage: $RDS_STORAGE_SIZE"
echo "$time_now engine version: $DB_ENGINE_VERSION"

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


########################################
###                                  ###
###   Steps to do the restore below  ###
###                                  ###
########################################


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
    sleep 60s
  done

  # Run restore and capture the task status
  echo "Start the Mssql restore..."
  RES_TASK_OUTPUT=$(sqlcmd_with_backoff $SQLCMD -S $RESTORE_ENDPOINT -U $RDS_USERNAME -P $RDS_PASSWORD -Q \
    "exec msdb.dbo.rds_restore_database @restore_db_name='$DB_NAME', \
    @s3_arn_to_restore_from='arn:aws:s3:::$BACKUP_TEMP_BUCKET/$DUMP_FILE';" \
    -W -s ',' -k 1)

  # Get the task id of the restore task status
  echo "Get the task id..."
  RES_TASK_ID=$(echo "$RES_TASK_OUTPUT" | csvcut -c "task_id" | grep "Task Id" | grep -o "[0-9]*")
  if [[ -n $RES_TASK_ID ]]; then
    echo "Started mssql restore with task id: $RES_TASK_ID"
  else
    echo "Error getting task id. Aborting."
    exit 1
  fi

  # Wait until restore status is SUCCESS before continuing
  function restore_task_status {
    sqlcmd_with_backoff $SQLCMD -S $RESTORE_ENDPOINT -U $RDS_USERNAME -P $RDS_PASSWORD -Q \
    "exec msdb.dbo.rds_task_status @task_id='$RES_TASK_ID'" -W -s "," -k 1 \
    | csvcut -c "lifecycle" | tail -1
  }

  RESTORE_TASK_STATUS=$(restore_task_status)
  echo "Restore status is $RESTORE_TASK_STATUS..."
  TEMP_RESTORE_STATUS=$RESTORE_TASK_STATUS
  while [[ $RESTORE_TASK_STATUS =~ (^CREATED$|^IN_PROGRESS$) ]]; do
    if [[ $RESTORE_TASK_STATUS != $TEMP_RESTORE_STATUS ]]; then
      echo "Restore status is $RESTORE_TASK_STATUS..."
    fi
    TEMP_RESTORE_STATUS=$RESTORE_TASK_STATUS
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

  # Cleanup dump file from the temp backup bucket
  echo "Removing dump file from the temp backups bucket: s3://$BACKUP_TEMP_BUCKET/"
  aws s3 rm $PROFILE_ARG --only-show-errors s3://$BACKUP_TEMP_BUCKET/$DUMP_FILE

else # Restore Postgres db
  get_time_now
  echo "$time_now Restoring Postgres backup..."
  pg_restore -l $DUMP_FILE | grep -v 'COMMENT - EXTENSION' > pg_restore.list
  pg_restore --exit-on-error -h $RESTORE_ENDPOINT -U $RDS_USERNAME -d $DB_NAME -L pg_restore.list $DUMP_FILE
  get_time_now
  echo "$time_now ...Done"
fi

# Check in on success
get_time_now
echo "$time_now Checkin to snitch..."
curl $CHECK_IN_URL
get_time_now
echo "$time_now ...Done"
