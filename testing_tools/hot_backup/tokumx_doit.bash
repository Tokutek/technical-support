#!/bin/bash

# This script will test hot backup functionality by running the
# hot backup while a "gauntlet" of operations within a Mongo DB
# are running.  The gauntlet.js file contains the operations that
# are executed. Additionally, this script references subordinate
# scripts such as mkmon, mongo-is-up, mongo-is-down and others that
# should be copied to ~/bin (bin directory off of the user's home 
# directory).  Add the ~/bin directory to the $PATH ENV variable and
# the script will then function correctly.


# Here are series of defensive checks to make sure the environment
# is ready for test execution.  The ENV variables listed are taken
# from machine.config which should be sourced via the user's .bashrc.
# This will ensure that all test execution happens under the tester's shell.

if [ -z "$MONGO_DIR" ]; then
    echo "Need to set MONGO_DIR"
    exit 1
fi
if [ ! -d "$MONGO_DIR" ]; then
    echo "Need to create directory MONGO_DIR"
    exit 1
fi
if [ "$(ls -A $MONGO_DIR)" ]; then
    echo "$MONGO_DIR contains files, cannot run script"
    exit 1
fi
if [ -z "$HOT_BACKUP_DIR" ]; then
    echo "Need to set HOT_BACKUP_DIR"
    exit 1
fi
if [ ! -d "$HOT_BACKUP_DIR" ]; then
    echo "Need to create directory HOT_BACKUP_DIR"
    exit 1
fi

# The TARBALL variable will ultimately be passed to mkmon
# which will process a path from Tim's nfs mounted archive of tarballs.
# It will require that this archive is mounted and ready to go.
# Most recently, this location was /nfs/tmcsrv but please verify.

export TARBALL=tokumx-e-1.4.2-linux-x86_64-main.tar.gz
export MONGO_TYPE=tokumx
export MONGO_REPLICATION=Y

export DB_NAME=sbtest
export MONGO_LOG=${MACHINE_NAME}.mongolog

export LOG_FILE_ORIGINAL=$PWD/log-original.log
export LOG_FILE_BACKUP=$PWD/log-backup.log

rm -f $LOG_FILE_ORIGINAL
rm -f $LOG_FILE_BACKUP



# keep it slow to start, we want to capturer to do the work
export RUN_HOT_BACKUPS_MBPS=1

# size of the dummy file
export DUMMY_FILE_MB=100

# unpack mongo files
echo "Creating mongo from ${TARBALL} in ${MONGO_DIR}"
pushd $MONGO_DIR
mkmon $TARBALL
popd

# $MONGO_REPL must be set to something for the server to start in replication mode
if [ ${MONGO_REPLICATION} == "Y" ]; then
    export MONGO_REPL="tmcRepl"
else
    unset MONGO_REPL
fi

echo "`date` | starting the ${MONGO_TYPE} server at ${MONGO_DIR}"
if [ ${MONGO_TYPE} == "tokumx" ]; then
    mongo-start-tokumx-fork
else
    mongo-start-pure-numa-fork
fi

mongo-is-up
echo "`date` | server is available"

# make sure replication is started
if [ ${MONGO_REPLICATION} == "Y" ]; then
    mongo-start-replication
fi

echo "`date` | Creating a $DUMMY_FILE_MB MB file to slow down the copier"
dd if=/dev/urandom of=$MONGO_DATA_DIR/dummy-file.txt bs=1048576 count=$DUMMY_FILE_MB

pauseSeconds=10

echo "`date` | Starting the backup"
tokumx-run-backup ${RUN_HOT_BACKUPS_MBPS} > ${MACHINE_NAME}-hot-backup.log &

echo "`date` | Pausing for ${pauseSeconds} second(s)"
sleep ${pauseSeconds}

echo "`date` | Executing the gauntlet"
# do stuff in test
$MONGO_DIR/bin/mongo test gauntlet.js 
# do stuff in db1
$MONGO_DIR/bin/mongo db1 gauntlet.js 
# do stuff in db2
$MONGO_DIR/bin/mongo db2 gauntlet.js 
# drop an entire database
$MONGO_DIR/bin/mongo db1 --eval "printjson(db.runCommand({dropDatabase:1}))"
# bulk loader
$MONGO_DIR/bin/mongoimport --db db4 --collection bulkloaded --type csv --file sample-data.txt --headerline


echo "`date` | Checking that backup is still running"
if ps aux | grep "tokumx-run-backu[p]" > /dev/null; then
    echo "  ... backup is running"
else
    echo "ERROR: backup either finished too fast or didn't run at all, exiting"
    exit 1
fi

echo "`date` | Speeding up the backup copier"
$MONGO_DIR/bin/mongo admin --eval "printjson(db.adminCommand({backupThrottle: 999999999}))"

echo "`date` | Waiting for backup to finish"
backupDone=0
while [ ${backupDone} == 0 ] ; do
    if ps aux | grep "tokumx-run-backu[p]" > /dev/null; then
        echo "  ... backup is running"
    else
        echo "  ... backup is finished"
        backupDone=1
    fi
    sleep 5
done


echo "Performing backup verification"


echo "  .. checking original database"

# check database hashes
$MONGO_DIR/bin/mongo admin --eval "printjson(db.runCommand('dbhash').md5)" | tee -a $LOG_FILE_ORIGINAL
$MONGO_DIR/bin/mongo db2   --eval "printjson(db.runCommand('dbhash').md5)" | tee -a $LOG_FILE_ORIGINAL
$MONGO_DIR/bin/mongo db4   --eval "printjson(db.runCommand('dbhash').md5)" | tee -a $LOG_FILE_ORIGINAL
$MONGO_DIR/bin/mongo test  --eval "printjson(db.runCommand('dbhash').md5)" | tee -a $LOG_FILE_ORIGINAL

# shutdown original database
mongo-stop
mongo-is-down


echo "  .. checking backup database"

# startup backup database
export MONGO_DATA_DIR=$HOT_BACKUP_DIR
if [ ${MONGO_TYPE} == "tokumx" ]; then
    mongo-start-tokumx-fork
else
    mongo-start-pure-numa-fork
fi
mongo-is-up

# check database hashes
$MONGO_DIR/bin/mongo admin --eval "printjson(db.runCommand('dbhash').md5)" | tee -a $LOG_FILE_BACKUP
$MONGO_DIR/bin/mongo db2   --eval "printjson(db.runCommand('dbhash').md5)" | tee -a $LOG_FILE_BACKUP
$MONGO_DIR/bin/mongo db4   --eval "printjson(db.runCommand('dbhash').md5)" | tee -a $LOG_FILE_BACKUP
$MONGO_DIR/bin/mongo test  --eval "printjson(db.runCommand('dbhash').md5)" | tee -a $LOG_FILE_BACKUP

# shutdown backup database
mongo-stop
mongo-is-down



echo "************************************************************************************"
echo "output from the backup process"
echo "************************************************************************************"
cat ${MACHINE_NAME}-hot-backup.log


echo "************************************************************************************"
echo "comparing output of original server and backup server"
echo "************************************************************************************"
diff $LOG_FILE_ORIGINAL $LOG_FILE_BACKUP
if [ $? == 0 ]; then
    echo "NO DIFFERENCES, GOOD STUFF!"
fi
