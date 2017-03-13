#!/bin/bash
export AWS_DEFAULT_REGION=us-east-1
# Install the postgres tools matching the engine version
export PSQL_TOOLS_VERSION
PSQL_TOOLS_VERSION=$(echo $PSQL_VERSION | awk -F\. '{print $1$2}')
sudo yum install -y postgresql$PSQL_TOOLS_VERSION

# Install nodejs
curl --silent --location https://rpm.nodesource.com/setup_6.x | bash -
sudo yum install -y nodejs

#export the database tables to csv in s3
export PGPASSWORD=$RDS_PASSWORD
node warehouse.js --export --app=$APP_NAME --s3bucket=$S3_BUCKET --pghost=$RDS_ENDPOINT --pgdb=$DATABASE_NAME


#perform a restore to redshift
npm install
export PGPASSWORD=$REDSHIFT_PASSWORD
node warehouse.js --restore --app=$APP_NAME --s3bucket=$S3_BUCKET --iamrole=$IAMROLE
