#!/bin/bash

export AWS_DEFAULT_REGION=us-east-1
export PGPASSWORD=$RDS_PASSWORD
export PSQL_TOOLS_VERSION=$(echo $PSQL_VERSION | awk -F\. '{print $1$2}')

# Install the postgres tools matching the engine version
sudo yum install -y postgresql$PSQL_TOOLS_VERSION

# dump the tables to CSV
mkdir tables
SCHEMA="public"
psql -Atc "select tablename from pg_tables where schemaname='$SCHEMA'" $DATABASE_NAME |\
  while read TBL; do
    psql -c "COPY $SCHEMA.$TBL TO STDOUT WITH CSV" $DATABASE_NAME > tables/$TBL.csv
  done

# Upload tables to s3 and encrypt them
aws s3 cp --sse aws:kms --sse-kms-key-id alias/warehouse-pipeline tables/*.csv s3://$S3_BUCKET/$APP_NAME-warehouse-pipeline/

# Delete the file
rm -rf tables
