#!/bin/sh
REMOTE=192.168.0.197			# IP Address of remote system
MODELTYPE=xml				# xml or sqlx
SKYBOXHOME=/opt/skyboxview		# Base directory of Skybox install
LOADUSERS=true				# true/false - Load users from model backup on to remote system
LOADTASKS=true				# true/false - Load tasks from model backup on to remote system
CUSTOMDIR=/opt/CUSTOMER			# Directory containinf PS scripts and data







##########################################################################################
##########################################################################################
## Do not edit anything below this line
##########################################################################################
##########################################################################################

DATE=$(which date)
echo "$($DATE) [INFO] - Script starting"
THISFILE=$(readlink -f $0)
SSH=$(which ssh)
GREP=$(which grep)
AWK=$(which awk)
MD5SUM=$(which md5sum)
RSYNC=$(which rsync)
SETTINGSFILENAME=$(ls -rt $SKYBOXHOME/data/settings_backup/settings_backup* | tail -1)
LOCALSTATE=$($GREP task_scheduling_activation $SKYBOXHOME/server/conf/sb_server.properties | $AWK -F= '{print $2}')
REMOTESTATE=$($SSH -oPasswordAuthentication=no $REMOTE "grep task_scheduling_activation $SKYBOXHOME/server/conf/sb_server.properties | $AWK -F= '{print \$2}'")
if [[ "$?" != 0 ]]; then
	echo "$($DATE) [ERROR] - SSH Keys are not setup"
	exit 1
fi

LOCALVERSION=$($GREP -E "^version" $SKYBOXHOME/server/bin/version.txt | $AWK -F= '{print $2}')
REMOTEVERSION=$($SSH $REMOTE "$GREP -E "^version" $SKYBOXHOME/server/bin/version.txt | $AWK -F= '{print \$2}'")
LOCALCALL=$($GREP REMOTE= $THISFILE | head -1 | awk '{print $1}' | awk -F= '{print $2}')
REMOTECALL=$($SSH $REMOTE "$GREP REMOTE= $THISFILE | head -1 | awk '{print \$1}' | awk -F= '{print \$2}'")
BACKUPFILE=$(ls $SKYBOXHOME/utility/bin/*.sbu 2>/dev/null)

if [[ "$BACKUPFILE" != "" ]]; then
	echo "$($DATE) [INFO] - Found backup file $BACKUPFILE.  Transfering to DR"
	$RSYNC -ra $BACKUPFILE $REMOTE:$BACKUPFILE
	if [[ "$?" != 0 ]]; then
        	echo "$($DATE) [ERROR] - SBU file transfer issue"
        	exit 1
	fi
fi

if [[ "$LOCALVERSION" != "$REMOTEVERSION" ]]; then
	echo "$($DATE) [ERROR] - Version mismatch.  Local=$LOCALVERSION Remote=$REMOTEVERSION"
	exit 1
fi

if [[ "$LOCALSTATE" == "false" ]] || [[ "$REMOTESTATE" == "true" ]]; then
	echo "$($DATE) [ERROR] - Task Scheduler issue.  Expecting LOCAL true and REMOTE false.  Received LOCAL $LOCALSTATE and REMOTE $REMOTESTATE"
	exit 1
fi

if [[ "$MODELTYPE" == "xml" ]]; then
	MODELPATH=$SKYBOXHOME/data/xml_models
	USERSFLAG="-coreusers"
	TASKSFLAG="-core"
elif [[ "$MODELTYPE" == "sqlx" ]]; then
	MODELPATH=$SKYBOXHOME/data/sqlx_models
	USERSFLAG="-user_tables"
	TASKSFLAG="-definition_tables"
else
	echo "$($DATE) [ERROR] - Invalid Model Type Specified.  Aborting..."
	exit 1
fi

if [[ "$LOADUSERS" == "false" ]]; then
	USERSFLAG=""
fi

if [[ "$LOADTASKS" == "false" ]]; then
	TASKSFLAG=""
fi

MODELFILENAME=$(ls -rt $MODELPATH/*backup_task* | tail -1)
MD5=$($MD5SUM $MODELFILENAME | awk '{print $1}')
echo "$($DATE) [INFO] - Copying model to remote system"
$RSYNC -ra $MODELFILENAME $REMOTE:$MODELPATH/
if [[ "$?" != 0 ]]; then
	echo "$($DATE) [ERROR] - Rsync failed"
	exit 1
fi
REMOTEMD5=$($SSH $REMOTE "$MD5SUM $MODELFILENAME | awk '{print \$1}'")

if [[ "$MD5" != "$REMOTEMD5" ]]; then
	echo "$($DATE) [ERROR] - MD5 Mismatch after model copy.  Aborting..."
	exit 1
fi

if [[ "$MODELTYPE" == "xml" ]]; then
	echo "$($DATE) [INFO] - Loading model on backup system - (load.sh -model $USERSFLAG $TASKSFLAG $MODELFILENAME)"
	$SSH $REMOTE "cd $SKYBOXHOME/server/bin ; ./load.sh -model $USERSFLAG $TASKSFLAG $MODELFILENAME"
else
	echo "$($DATE) [INFO] - Loading model on backup system - (sqlxrestore.sh -model_tables $USERSFLAG $TASKSFLAG $MODELFILENAME)"
	$SSH $REMOTE "cd $SKYBOXHOME/server/bin ; ./sqlxrestore.sh -model_tables $USERSFLAG $TASKSFLAG $MODELFILENAME"
fi
if [[ "$?" != 0 ]]; then
	echo "$($DATE) [ERROR] - Model load failed"
	exit 1
fi
echo "$($DATE) [INFO] - Model load complete"	

echo "$($DATE) [INFO] - Copying settings to remote system"
$RSYNC -ra $SETTINGSFILENAME $REMOTE:$SKYBOXHOME/data/settings_backup/
if [[ "$?" != 0 ]]; then
	echo "$($DATE) [ERROR] - Rsync of setting file failed.  Is it being backed up?"
	exit 1
fi
MD5=$($MD5SUM $SETTINGSFILENAME | awk '{print $1}')
REMOTEMD5=$($SSH $REMOTE "$MD5SUM $SETTINGSFILENAME | awk '{print \$1}'")

if [[ "$MD5" != "$REMOTEMD5" ]]; then
        echo "$($DATE) [ERROR] - MD5 Mismatch after settings copy.  Aborting..."
        exit 1
fi

echo "$($DATE) [INFO] - Unzipping settings on remote server"
$SSH $REMOTE "unzip -qo $SETTINGSFILENAME -d $SKYBOXHOME"
if [[ "$?" != 0 ]]; then
	echo "$($DATE) [ERROR] - Remote unzip failed"
	exit 1
fi

echo "$($DATE) [INFO] - Copying fw_configs to remote system"
$RSYNC --delete -ra $SKYBOXHOME/data/fw_configs $REMOTE:$SKYBOXHOME/data/
if [[ "$?" != 0 ]]; then
	echo "$($DATE) [ERROR] - Rsync failed to copy configuration files"
	exit 1
fi

$SSH $REMOTE "cd $SKYBOXHOME/server/conf ; sed 's/task_scheduling_activation=true/task_scheduling_activation=false/g' sb_server.properties > sb_server.properties.temp ; mv sb_server.properties.temp sb_server.properties"
if [[ "$?" != 0 ]]; then
	echo "$($DATE) [ERROR] - Task scheduler assignment failed"
	exit 1
fi

echo "$($DATE) [INFO] - Copying PS Directory $CUSTOMDIR"
$RSYNC --delete -ra $CUSTOMDIR/ $REMOTE:$CUSTOMDIR
if [[ "$?" != 0 ]]; then
	echo "$($DATE) [ERROR] - Rsync failed to copy customizations in $CUSTOMDIR"
	exit 1
fi

echo "$($DATE) [INFO] - Copying .bashrc"
$RSYNC -ra /home/skyboxview/.bashrc $REMOTE:/home/skyboxview/
if [[ "$?" != 0 ]]; then
        echo "$($DATE) [ERROR] - Rsync failed to copy .bashrc"
        exit 1
fi

$SSH $REMOTE "sed 's/$LOCALCALL/$REMOTECALL/g' $THISFILE > $THISFILE.temp ; mv $THISFILE.temp $THISFILE ; chmod +x $THISFILE"

echo "$($DATE) [INFO] - Script Complete"
exit 0
