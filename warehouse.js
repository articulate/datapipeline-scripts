const baby = require("babyparse")
const fs = require("fs")
const shell = require("shelljs")
var argv = require('yargs').argv

var redshift_command = `psql -h ${argv.rshost || "localhost"} -p ${argv.rsport || "5439"} -U ${argv.rsuser || "articulatedb"} -d ${argv.rsdb || "articulate"} -c`
var psql_command = `psql -h ${argv.pghost || "localhost"} -p ${argv.pgport || "5432"} -U ${argv.pguser || "articulatedb"} -d "${argv.pgdb}" -Atc`

//options for babyparse
const schemaConfig = {
  delimiter: "|",
  quoteChar: '"',
  header: true,
  dynamicTyping: true,
  skipEmptyLines: true
}

//psql data types mapped to redshift data types
const mappings = {
  jsonb: "varchar",
  text: "varchar",
  int8: "bigint",
  int4: "integer",
  uuid: "char",
  numeric: "decimal"
}

//these redshift data types do not take length as an arg
const noLength = [
  "timestamptz",
  "bool",
  "bigint",
  "integer",
  "decimal"
]

//tables to ignore in the export
const ignoreTables = [
  "knex_migrations",
  "knex_migrations_lock",
  "awsdms_ddl_audit",
  "authorLabelSets",
  "authorSettings",
  "SequelizeMeta"
]

//this builds the createTable command to be used against the redshift cluster
var createTable = (file) => {
  const schema = fs.readFileSync(`${file}`, 'utf8')

  var schemaData = baby.parse(schema, schemaConfig)
  var fields = []

  for (let value of schemaData.data) {
    //replace psql types with redshift types
    var field_type = mappings[value.udt_name] ? mappings[value.udt_name] : value.udt_name

    //use max length values for fields that have them
    var length = value.character_maximum_length === "" ? "MAX" : value.character_maximum_length

    //check for field types that do not require a length
    var final_field_type = noLength.includes(field_type) ? field_type.toUpperCase() : `${field_type.toUpperCase()}(${length})`

    fields = fields.concat(`\\"${value.column_name}\\" ${final_field_type}`)
  }
  return(`${redshift_command} \"create table \\"${argv.app}_${file.split(".")[0].replace("_schema", "")}_test\\" (${fields.join(", ")})\"`)
}

//this builds the copyData command to be used to import the data into redshift
var copyData = (file) => {
  return(`${redshift_command} \"copy \\"${argv.app}_${file.split("/")[1].split(".")[0]}_test\\" from 's3://${argv.s3bucket}/${argv.app}-warehouse-pipeline/${file.split("/")[1].split(".")[0]}.csv' iam_role '${argv.iamrole}' csv delimiter '|' quote '\\"' region 'us-east-1' dateformat 'auto' IGNOREHEADER as 1\"`)
}

if (argv.export) {
  //grab the list of tables in the psql database
  var tables = shell.exec(`${psql_command} "select tablename from pg_tables where schemaname='public'"`, {silent:true}).stdout

  //parse the stdout into a list of tables
  tables = tables.trimRight().split("\n")

  //exclude tables that are not useful
  var tablesToExport = []
  for (let value of tables) {
    tablesToExport = ignoreTables.includes(value) ? tablesToExport.concat() : tablesToExport.concat(value)
  }

  //dump the tables schema and data to csv files
  for (let value in tablesToExport) {
    shell.exec(`${psql_command} "COPY public.${tablesToExport[value]} TO STDOUT DELIMITER '|' CSV HEADER"`, {silent: true}).to(`${tablesToExport[value]}.csv`)
    shell.exec(`${psql_command} "COPY (select column_name, udt_name, character_maximum_length from INFORMATION_SCHEMA.COLUMNS where table_name = '${tablesToExport[value]}') TO STDOUT DELIMITER '|' CSV HEADER"`, {silent: true}).to(`${tablesToExport[value]}_schema.csv`)
  }

  //TODO put the tables in S3 use `--sse aws:kms --sse-kms-key-id alias/${ argv.kmsalias || "warehouse-pipeline"}` later
  for (let value in tablesToExport) {
    shell.exec(`aws s3 cp ${tablesToExport[value]}.csv s3://${argv.s3bucket}/${argv.app}-warehouse-pipeline/`)
    shell.exec(`aws s3 cp ${tablesToExport[value]}_schema.csv s3://${argv.s3bucket}/${argv.app}-warehouse-pipeline/`)
  }
}

if (argv.restore) {
  console.log("performing restore to redshift using the following files:")

  //grab a list of the files in the s3 bucket for this app
  var csvfiles = JSON.parse(shell.exec(`aws s3api list-objects --bucket ${argv.s3bucket} --prefix ${argv.app}-warehouse-pipeline --query Contents[].Key --output json`, {silent: true}).stdout)

  //download the files from s3 for restore
  for (let value in csvfiles) {
    shell.exec(`aws s3 cp s3://${argv.s3bucket}/${csvfiles[value]} .`)
  }

  //drop tables from redshift for a clean import
  for (let value in csvfiles) {
    if (csvfiles[value].includes("schema")) {
      //we don't want to work on the schema files here
    } else {
      shell.exec(`${redshift_command} \"drop table ${argv.app}_${csvfiles[value].split("/")[1].split(".")[0]}_test\"`)
    }
  }

  //pass the schema file to the create table functions
  for (let value in csvfiles) {
    if (csvfiles[value].includes("schema")) {
      var createTableCommand = createTable(`${csvfiles[value].split("/")[1]}`)
      shell.exec(createTableCommand)
    }
  }

  //pass the data files into the copyData function and execute the command
  for (let value in csvfiles) {
    if (csvfiles[value].includes("schema")) {
      //we don't want to work on the schema files here
    } else {
      var copyDataCommand = copyData(`${csvfiles[value]}`)
      shell.exec(copyDataCommand)
    }
  }

  //clean up the files in s3
  for (let value in csvfiles) {
    shell.exec(`aws s3 rm s3://${argv.s3bucket}/${csvfiles[value]}`)
  }
  //cleanup local csv files
  shell.exec("rm *.csv")
}

if (argv.help) {
  console.log(`
     This script has two functions. It can export tables and their schemas to s3
     for restore into redshift, and it can restore tables and their table 
     data into redshift from the exported data sets in s3.

     Commands:
      --export (tell the script to export data from a database)
      --restore (trigger the restore of a data set from a database)
      --help (you got this)`)
}
