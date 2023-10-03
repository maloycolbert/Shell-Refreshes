if [ "${bamboo_planRepository_branch}" == "dev" ]
then
	_d_DEST_TOKEN=${bamboo_dev_token_secret}
	_d_DEST_PROJECT='project-dev'
fi
if [[ "${bamboo_planRepository_branch}" = "test" ]]
then
	_d_DEST_TOKEN=${bamboo_test_token_secret}
	_d_DEST_PROJECT='project-test'
fi

if [ -z "${_d_DEST_PROJECT}" ]
then
	echo "Invalid branch. You can currently only sync to dev / test.";
	exit 1; 
fi

_d_SITE='project'

# create tmp folders
echo "Creating tmp folders"
mkdir ./tmp/
mkdir ./tmp/site/
mkdir ./tmp/site/${_d_SITE}/
mkdir ./tmp/site/${_d_SITE}/uploads/
mkdir ./tmp/site/${_d_SITE}/plugins/

# SOURCE
# TEST
_d_SOURCE_PROJECT='web-project'
echo "Connecting to okd-cluster.liberty.edu - Project: ${_d_SOURCE_PROJECT}"
oc login okd-cluster.liberty.edu --token=${bamboo_prod_token_secret} --insecure-skip-tls-verify
oc project ${_d_SOURCE_PROJECT}
setProject=`oc project -q`

if [ "${setProject}" == "${_d_SOURCE_PROJECT}" ]
then
	resume="true"
else
	echo "Not on the right project somehow. You are on ${setProject} but you tried to switch to ${_d_SOURCE_PROJECT}"
	exit 1
fi


echo "Getting Pod Name"
_d_SOURCE_currentPods=`oc get pods -o=json | jq -r '.items'`
for _d_SOURCE_row in $(echo "${_d_SOURCE_currentPods}" | jq -r '.[] | @base64'); do
    _d_SOURCE_innerPod=`echo ${_d_SOURCE_row} | base64 -di | jq -r '.metadata.name'`
	if [[ "${_d_SOURCE_innerPod}" =~ "wordpress-" ]]
	then
		_d_SOURCE_WPPod="${_d_SOURCE_innerPod}"
	fi
done
echo "Pod Name: ${_d_SOURCE_WPPod}"


# copy file from SOURCE to local
echo "Copying Plugins from ${_d_SOURCE_PROJECT} - ${_d_SOURCE_WPPod}"
_d_copyErrorCount=0;
until 
	oc rsync ${_d_SOURCE_WPPod}:/var/www/html/wp-content/plugins/ ./tmp/site/${_d_SITE}/plugins/ --no-perms=true -q --progress=true
do 
	_d_copyErrorCount=$(( ${_d_copyErrorCount} + 1 ));
	echo "Attempt #${_d_copyErrorCount}";
	if [ "${_d_copyErrorCount}" -gt "2" ] 
	then 
		echo "Error copying plugins";
		# read -n 1 -s -r -p "Press any key to continue..."
		exit 1; 
	else 
		echo "trying one more time in 10s"
		sleep 10; 
	fi; 
done;

echo "Copying Uploads from ${_d_SOURCE_PROJECT} - ${_d_SOURCE_WPPod}"
_d_copyErrorCount=0;
until 
	oc rsync ${_d_SOURCE_WPPod}:/var/www/html/wp-content/uploads/ ./tmp/site/${_d_SITE}/uploads/ --no-perms=true -q --progress=true
do 
	_d_copyErrorCount=$(( ${_d_copyErrorCount} + 1 ));
	echo "Attempt #${_d_copyErrorCount}";
	if [ "${_d_copyErrorCount}" -gt "2" ] 
	then 
		echo "Error copying uploads";
		# read -n 1 -s -r -p "Press any key to continue..."
		exit 1; 
	else 
		echo "trying one more time in 10s"
		sleep 10; 
	fi; 
done;

echo "Logging out of okd-cluster.liberty.edu"
oc logout

# DESTINATION (dev/test)
echo "Connecting to okd-cluster.liberty.edu - Project: ${_d_DEST_PROJECT}"
oc login okd-cluster.liberty.edu --token=${_d_DEST_TOKEN} --insecure-skip-tls-verify
oc project ${_d_DEST_PROJECT}
setProject=`oc project -q`

if [ "${setProject}" == "${_d_DEST_PROJECT}" ]
then
	resume="true"
else
	echo "Not on the right project somehow. You are on ${setProject} but you tried to switch to ${_d_DEST_PROJECT}"
	exit 1
fi

echo "Getting Pod Name"
_d_DEST_currentPods=`oc get pods -o=json | jq -r '.items'`
for _d_DEST_row in $(echo "${_d_DEST_currentPods}" | jq -r '.[] | @base64'); do
    _d_DEST_innerPod=`echo ${_d_DEST_row} | base64 -di | jq -r '.metadata.name'`
	if [[ "${_d_DEST_innerPod}" =~ "-${bamboo_planRepository_branch}-" ]] # to handle test/test2/test3
	then
		_d_DEST_WPPod="${_d_DEST_innerPod}"
		break
	elif [[ "${_d_DEST_innerPod}" =~ "wordpress-" ]] # to handle dev
	then
		_d_DEST_WPPod="${_d_DEST_innerPod}"
	fi
done
echo "Pod Name: ${_d_DEST_WPPod}"

# copy file from SOURCE to local
echo "Copying Plugins to ${_d_DEST_PROJECT} - ${_d_DEST_WPPod}"
_d_copyErrorCount=0;
until 
	oc rsync ./tmp/site/${_d_SITE}/plugins/ ${_d_DEST_WPPod}:/var/www/html/wp-content/plugins/ --no-perms=true -q --progress=true
do 
	_d_copyErrorCount=$(( ${_d_copyErrorCount} + 1 ));
	echo "Attempt #${_d_copyErrorCount}";
	if [ "${_d_copyErrorCount}" -gt "2" ] 
	then 
		echo "Error copying plugins";
		# read -n 1 -s -r -p "Press any key to continue..."
		exit 1; 
	else 
		echo "trying one more time in 10s"
		sleep 10; 
	fi; 
done;


echo "Copying Uploads to ${_d_DEST_PROJECT} - ${_d_DEST_WPPod}"
_d_copyErrorCount=0;
until 
	oc rsync ./tmp/site/${_d_SITE}/uploads/ ${_d_DEST_WPPod}:/var/www/html/wp-content/uploads/  --no-perms=true -q --progress=true
do 
	_d_copyErrorCount=$(( ${_d_copyErrorCount} + 1 ));
	echo "Attempt #${_d_copyErrorCount}";
	if [ "${_d_copyErrorCount}" -gt "2" ] 
	then 
		echo "Error copying uploads";
		# read -n 1 -s -r -p "Press any key to continue..."
		exit 1; 
	else 
		echo "trying one more time in 10s"
		sleep 10; 
	fi; 
done;

echo "Logging out of okd-cluster.liberty.edu"
oc logout

#remove all tmp files
echo "Removing ./tmp/site/"
rm -r ./tmp/site/
echo "./tmp/site/ Removed."

# read -n 1 -s -r -p "Press any key to continue..."
