#!/bin/bash

export AWS_DEFAULT_REGION=us-east-1
export PGPASSWORD=$RDS_PASSWORD
export PSQL_TOOLS_VERSION=$(echo $PSQL_VERSION | awk -F\. '{print $1$2}')

# Install the postgres tools matching the engine version
sudo yum install -y postgresql$PSQL_TOOLS_VERSION

# dump the tables to CSV
mkdir tables
SCHEMA="public"
psql -h $RDS_ENDPOINT -U $RDS_USERNAME -Atc "select tablename from pg_tables where schemaname='$SCHEMA'" -d $DATABASE_NAME |\
  while read TBL; do
    psql -h $RDS_ENDPOINT -U $RDS_USERNAME -c "COPY $SCHEMA.$TBL TO STDOUT WITH CSV" -d $DATABASE_NAME > tables/$TBL.csv
  done

#cleanup empty tables (views) and migration tables supress error messages from removing things that don't exist
rm tables/knex*.csv >/dev/null 2>&1 
find tables/ -size  0 -print0 |xargs -0 rm

# Upload tables to s3 and encrypt them
aws s3 cp --sse aws:kms --sse-kms-key-id alias/warehouse-pipeline tables/*.csv s3://$S3_BUCKET/$APP_NAME-warehouse-pipeline/

# Delete the tables folder
rm -rf tables
