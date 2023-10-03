if [ "${bamboo_planRepository_branch}" == "dev" ]
then
	_sync_TARGET_DB="ALLUVION_DEV"
	_sync_TARGET_USER="ALLUVION_DEV_USER"
	_sync_TARGET_PASS=${bamboo_alluvion_dev_db_secret}
	_sync_TARGET_TOKEN=${bamboo_alluvion_dev_token_secret}
	_sync_TARGET_PROJECT="alluvion-dev"
	_sync_TARGET_URL="alluvion-dev.okd.liberty.edu"
fi
if [ "${bamboo_planRepository_branch}" == "test" ]
then
	_sync_TARGET_DB="ALLUVION_TEST"
	_sync_TARGET_USER="ALLUVION_TEST_USER"
	_sync_TARGET_PASS=${bamboo_alluvion_test_db_secret}
	_sync_TARGET_TOKEN=${bamboo_alluvion_test_token_secret}
	_sync_TARGET_PROJECT="alluvion-test"
	_sync_TARGET_URL="alluvion-test.okd.liberty.edu"
fi

if [ -z "${_sync_TARGET_DB}" ]
then
	throw "Invalid branch. You can currently only sync dev, and test.";
	exit 1; 
fi

esc() {
    printf "%s\n" "$1" | sed -e "s/\"/\\\\\"/g"
}

# Set Date
# read YYYY MM DD <<<$(date +'%Y %m %d')
_sync_SITE="alluvion"


# PROD set to test for now for testing
_sync_SOURCE_DB='WP_ALLUVION'
_sync_SOURCE_USER='WP_ALLUVION'
_sync_SOURCE_PASS=${bamboo_alluvion_prod_db_secret} #OKD PROD
_sync_SOURCE_PROJECT='web-alluvion' #OKD PROD
_sync_SOURCE_URL='alluvion.okd.liberty.edu'
_sync_SOURCE_VANITY_URL='www.alluvionstage.com'

oc login okd-cluster.liberty.edu --token=${bamboo_alluvion_prod_token_secret} --insecure-skip-tls-verify
oc project ${_sync_SOURCE_PROJECT}
setProject=`oc project -q`
if [ "${setProject}" == "${_sync_SOURCE_PROJECT}" ]
then
	resume="true"
else
	echo "Not on the right project somehow. You are on ${setProject} but you tried to switch to ${_sync_SOURCE_PROJECT}"
	# read -n 1 -s -r -p "Press any key to continue..."
	exit 1
fi

_sync_SOURCE_currentPods=`oc get pods -o=json | jq -r '.items'`
for _sync_SOURCE_row in $(echo "${_sync_SOURCE_currentPods}" | jq -r '.[] | @base64'); do
    _sync_SOURCE_innerPod=`echo ${_sync_SOURCE_row} | base64 -di | jq -r '.metadata.name'`
	if [[ "${_sync_SOURCE_innerPod}" =~ "mysql" ]]
	then
		_sync_SOURCE_mysqlPod="${_sync_SOURCE_innerPod}"
	fi
done
echo "this is PROD mysql pod: ${_sync_SOURCE_mysqlPod}"


# excute dump from PROD
oc exec -i ${_sync_SOURCE_mysqlPod} -- bash -c "mysqldump -h 10.255.96.153 -u ${_sync_SOURCE_USER} -p${_sync_SOURCE_PASS} ${_sync_SOURCE_DB} > ${_sync_SITE}.prod-${bamboo_planRepository_branch}.db.backup.auto.sql";

# Create new directory on local/bamboo
mkdir ${_sync_SITE}.prod-${bamboo_planRepository_branch}.db.backup.auto
cd ./${_sync_SITE}.prod-${bamboo_planRepository_branch}.db.backup.auto/

# copy file from PROD to local/bamboo
oc rsync --no-perms=false ${_sync_SOURCE_mysqlPod}:/opt/app-root/src/${_sync_SITE}.prod-${bamboo_planRepository_branch}.db.backup.auto.sql . 
cd ../
echo "copied prod database to local/bamboo"
oc logout

oc login okd-cluster.liberty.edu --token=${_sync_TARGET_TOKEN} --insecure-skip-tls-verify
oc project ${_sync_TARGET_PROJECT}
setProject=`oc project -q`
if [ "${setProject}" == "${_sync_TARGET_PROJECT}" ]
then
	resume="true"
else
	echo "Not on the right project somehow. You are on ${setProject} but you tried to switch to ${_sync_TARGET_PROJECT}"
	exit 1
fi

_sync_currentPods=`oc get pods -o=json | jq -r '.items'`
for _sync_row in $(echo "${_sync_currentPods}" | jq -r '.[] | @base64'); do
	# skip over pod if not "running"
    _sync_innerPodPhase=`echo ${_sync_row} | base64 -di | jq -r '.status.phase'`
	if [[ "${_sync_innerPodPhase}" != "Running" ]]
	then
		continue
	fi

    _sync_innerPod=`echo ${_sync_row} | base64 -di | jq -r '.metadata.name'`
	if [[ "${_sync_innerPod}" =~ "mysql" ]]
	then
		_sync_mysqlPod="${_sync_innerPod}"
		break;
	fi
done

echo "mysql pod: ${_sync_mysqlPod}"

# make backup in case something goes wrong
echo "Backing up current database to ${_sync_SITE}.${bamboo_planRepository_branch}.db.backup.auto.sql and saving copy to local/bamboo"
oc exec -i ${_sync_mysqlPod} -- bash -c "mysqldump -h 10.255.124.80 -u ${_sync_TARGET_USER} -p${_sync_TARGET_PASS} ${_sync_TARGET_DB} > ${_sync_SITE}.${bamboo_planRepository_branch}.db.backup.auto.sql";

# copying file to target server
_sync_mysqlErrorCount=0;
echo "Copying ${_sync_SITE}.prod-${bamboo_planRepository_branch}.db.backup.auto.sql to ${_sync_TARGET_PROJECT^^} MySQL server";
until 
	oc rsync --no-perms ./${_sync_SITE}.prod-${bamboo_planRepository_branch}.db.backup.auto ${_sync_mysqlPod}:/opt/app-root/src/	
	oc exec -i ${_sync_mysqlPod} -- bash -c "chmod a=rx ${_sync_SITE}.prod-${bamboo_planRepository_branch}.db.backup.auto"
do
	_sync_mysqlErrorCount=$(( ${_sync_mysqlErrorCount} + 1 ));
	echo "Attempt #${_sync_mysqlErrorCount}";
	if [ "${_sync_mysqlErrorCount}" -gt "10" ] 
	then 
		throw "Error replacing values";
		exit 1; 
	else 
		echo "trying again in 10s"
		sleep 10; 
	fi; 
done;

# import into db
echo "Importing ${_sync_SITE}.prod-${bamboo_planRepository_branch}.db.backup.auto.sql";
_sync_mysqlErrorCount=0;
until 
	oc exec -i ${_sync_mysqlPod} -- bash -c "mysql -h 10.255.124.80 -u ${_sync_TARGET_USER} -p${_sync_TARGET_PASS} ${_sync_TARGET_DB} < ${_sync_SITE}.prod-${bamboo_planRepository_branch}.db.backup.auto/${_sync_SITE}.prod-${bamboo_planRepository_branch}.db.backup.auto.sql"; 
do 
	_sync_mysqlErrorCount=$(( ${_sync_mysqlErrorCount} + 1 ));
	echo "Attempt #${_sync_mysqlErrorCount}";
	if [ "${_sync_mysqlErrorCount}" -gt "10" ] 
	then 
		throw "Error Importing Database";
		exit 1; 
	else 
		echo "trying again in 10s"
		sleep 10; 
	fi; 
done;

# in wp-options make site not public
sync_mysqlErrorCount=0;
echo "Updating blog_public options and setting site to non-index";
until 
	oc exec -i ${_sync_mysqlPod} -- bash -c "mysql -h 10.255.124.80 -u ${_sync_TARGET_USER} -p${_sync_TARGET_PASS} ${_sync_TARGET_DB} -e 'update wp_options set option_value = \"0\" WHERE option_name=\"blog_public\"'";
    
do 
	_sync_mysqlErrorCount=$(( ${_sync_mysqlErrorCount} + 1 ));
	echo "Attempt #${_sync_mysqlErrorCount}";
	if [ "${_sync_mysqlErrorCount}" -gt "10" ] 
	then 
		throw "Error replacing values";
		exit 1; 
	else 
		echo "trying again in 10s"
		sleep 10; 
	fi; 
done;

# replace domains in database
# Replace wp_option urls
_sync_mysqlErrorCount=0;
echo 'Replacing wp_options table urls';
until 
	oc exec -i ${_sync_mysqlPod} -- bash -c "mysql -h 10.255.124.80 -u ${_sync_TARGET_USER} -p${_sync_TARGET_PASS} ${_sync_TARGET_DB} -e 'update wp_options set option_value = replace(option_value, \"${_sync_SOURCE_URL}\", \"${_sync_TARGET_URL}\"); update wp_options set option_value = replace(option_value, \"${_sync_SOURCE_VANITY_URL}\", \"${_sync_TARGET_URL}\");'"; 
 
do 
	_sync_mysqlErrorCount=$(( ${_sync_mysqlErrorCount} + 1 ));
	echo "Attempt #${_sync_mysqlErrorCount}";
	if [ "${_sync_mysqlErrorCount}" -gt "10" ] 
	then 
		throw "Error replacing values";
		exit 1; 
	else 
		echo "trying again in 10s"
		sleep 10; 
	fi; 
done;

# Replace wp_posts table . urls, guids urls, and pinged urls
_sync_mysqlErrorCount=0;
echo 'Replacing wp_posts table urls';
until 
	# regular url replace
	oc exec -i ${_sync_mysqlPod} -- bash -c "mysql -h 10.255.124.80 -u ${_sync_TARGET_USER} -p${_sync_TARGET_PASS} ${_sync_TARGET_DB} -e 'update wp_posts set post_content = replace(post_content, \"${_sync_SOURCE_URL}\", \"${_sync_TARGET_URL}\"); update wp_posts set guid = replace(guid, \"${_sync_SOURCE_URL}\", \"${_sync_TARGET_URL}\"); update wp_posts set pinged = replace(pinged, \"${_sync_SOURCE_URL}\", \"${_sync_TARGET_URL}\");'";
	# vanity url replace
	oc exec -i ${_sync_mysqlPod} -- bash -c "mysql -h 10.255.124.80 -u ${_sync_TARGET_USER} -p${_sync_TARGET_PASS} ${_sync_TARGET_DB} -e 'update wp_posts set post_content = replace(post_content, \"${_sync_SOURCE_VANITY_URL}\", \"${_sync_TARGET_URL}\"); update wp_posts set guid = replace(guid, \"${_sync_SOURCE_VANITY_URL}\", \"${_sync_TARGET_URL}\"); update wp_posts set pinged = replace(pinged, \"${_sync_SOURCE_VANITY_URL}\", \"${_sync_TARGET_URL}\");'";	
do 
	_sync_mysqlErrorCount=$(( ${_sync_mysqlErrorCount} + 1 ));
	echo "Attempt #${_sync_mysqlErrorCount}";
	if [ "${_sync_mysqlErrorCount}" -gt "10" ] 
	then 
		throw "Error replacing values";
		exit 1; 
	else 
		echo "trying again in 10s"
		sleep 10; 
	fi; 
done;

# Replace wp_postmeta urls
_sync_mysqlErrorCount=0;
echo 'Replacing wp_postmeta table urls';
until 
	oc exec -i ${_sync_mysqlPod} -- bash -c "mysql -h 10.255.124.80 -u ${_sync_TARGET_USER} -p${_sync_TARGET_PASS} ${_sync_TARGET_DB} -e 'update wp_postmeta set meta_value = replace(meta_value, \"${_sync_SOURCE_URL}\", \"${_sync_TARGET_URL}\"); update wp_postmeta set meta_value = replace(meta_value, \"${_sync_SOURCE_VANITY_URL}\", \"${_sync_TARGET_URL}\");'";
do 
	_sync_mysqlErrorCount=$(( ${_sync_mysqlErrorCount} + 1 ));
	echo "Attempt #${_sync_mysqlErrorCount}";
	if [ "${_sync_mysqlErrorCount}" -gt "10" ] 
	then 
		throw "Error replacing values";
		exit 1; 
	else 
		echo "trying again in 10s"
		sleep 10; 
	fi; 
done;

# Replace wp_usermeta urls
_sync_mysqlErrorCount=0;
echo 'Replacing wp_usermeta table urls';
until 
	oc exec -i ${_sync_mysqlPod} -- bash -c "mysql -h 10.255.124.80 -u ${_sync_TARGET_USER} -p${_sync_TARGET_PASS} ${_sync_TARGET_DB} -e 'update wp_usermeta set meta_value = replace(meta_value, \"${_sync_SOURCE_URL}\", \"${_sync_TARGET_URL}\"); update wp_usermeta set meta_value = replace(meta_value, \"${_sync_SOURCE_VANITY_URL}\", \"${_sync_TARGET_URL}\");'";
do 
	_sync_mysqlErrorCount=$(( ${_sync_mysqlErrorCount} + 1 ));
	echo "Attempt #${_sync_mysqlErrorCount}";
	if [ "${_sync_mysqlErrorCount}" -gt "10" ] 
	then 
		throw "Error replacing values";
		exit 1; 
	else 
		echo "trying again in 10s"
		sleep 10; 
	fi; 
done;

# Replace wp_yoast_seo_links table . permalink urls
_sync_mysqlErrorCount=0;
echo 'Replacing wp_yoast_seo_links table urls';
until 
	oc exec -i ${_sync_mysqlPod} -- bash -c "mysql -h 10.255.124.80 -u ${_sync_TARGET_USER} -p${_sync_TARGET_PASS} ${_sync_TARGET_DB} -e 'update wp_yoast_seo_links set url = replace(url, \"${_sync_SOURCE_URL}\", \"${_sync_TARGET_URL}\"); update wp_yoast_seo_links set url = replace(url, \"${_sync_SOURCE_VANITY_URL}\", \"${_sync_TARGET_URL}\");'";
do 
	_sync_mysqlErrorCount=$(( ${_sync_mysqlErrorCount} + 1 ));
	echo "Attempt #${_sync_mysqlErrorCount}";
	if [ "${_sync_mysqlErrorCount}" -gt "10" ] 
	then 
		throw "Error replacing values";
		exit 1; 
	else 
		echo "trying again in 10s"
		sleep 10; 
	fi; 
done;

# Replace wp_yoast_indexable urls table . permalink urls, twitter_image, open_graph_image, & open_graph_image_meta
_sync_mysqlErrorCount=0;
echo 'Replacing wp_yoast_indexable table urls';
until 
	# replace OKD urls
	oc exec -i ${_sync_mysqlPod} -- bash -c "mysql -h 10.255.124.80 -u ${_sync_TARGET_USER} -p${_sync_TARGET_PASS} ${_sync_TARGET_DB} -e 'update wp_yoast_indexable set permalink = replace(permalink, \"${_sync_SOURCE_URL}\", \"${_sync_TARGET_URL}\"); update wp_yoast_indexable set twitter_image = replace(twitter_image, \"${_sync_SOURCE_URL}\", \"${_sync_TARGET_URL}\"); update wp_yoast_indexable set open_graph_image = replace(open_graph_image, \"${_sync_SOURCE_URL}\", \"${_sync_TARGET_URL}\"); update wp_yoast_indexable set open_graph_image_meta = replace(open_graph_image_meta, \"${_sync_SOURCE_URL}\", \"${_sync_TARGET_URL}\");'";
	# replace Vanity urls
	oc exec -i ${_sync_mysqlPod} -- bash -c "mysql -h 10.255.124.80 -u ${_sync_TARGET_USER} -p${_sync_TARGET_PASS} ${_sync_TARGET_DB} -e 'update wp_yoast_indexable set permalink = replace(permalink, \"${_sync_SOURCE_VANITY_URL}\", \"${_sync_TARGET_URL}\"); update wp_yoast_indexable set twitter_image = replace(twitter_image, \"${_sync_SOURCE_VANITY_URL}\", \"${_sync_TARGET_URL}\"); update wp_yoast_indexable set open_graph_image = replace(open_graph_image, \"${_sync_SOURCE_VANITY_URL}\", \"${_sync_TARGET_URL}\"); update wp_yoast_indexable set open_graph_image_meta = replace(open_graph_image_meta, \"${_sync_SOURCE_VANITY_URL}\", \"${_sync_TARGET_URL}\");'";
do 
	_sync_mysqlErrorCount=$(( ${_sync_mysqlErrorCount} + 1 ));
	echo "Attempt #${_sync_mysqlErrorCount}";
	if [ "${_sync_mysqlErrorCount}" -gt "10" ] 
	then 
		throw "Error replacing values";
		exit 1; 
	else 
		echo "trying again in 10s"
		sleep 10; 
	fi; 
done;

# Replace wp_revslider_slides urls

_sync_mysqlErrorCount=0;
echo 'Replacing wp_revslider_slides table urls';
until 
	# regular url replace
	oc exec -i ${_sync_mysqlPod} -- bash -c "mysql -h 10.255.124.80 -u ${_sync_TARGET_USER} -p${_sync_TARGET_PASS} ${_sync_TARGET_DB} -e 'update wp_revslider_slides set params = replace(params, \"${_sync_SOURCE_URL}\", \"${_sync_TARGET_URL}\"); update wp_revslider_slides set layers = replace(layers, \"${_sync_SOURCE_URL}\", \"${_sync_TARGET_URL}\");'";

	# vanity url replace
	oc exec -i ${_sync_mysqlPod} -- bash -c "mysql -h 10.255.124.80 -u ${_sync_TARGET_USER} -p${_sync_TARGET_PASS} ${_sync_TARGET_DB} -e 'update wp_revslider_slides set params = replace(params, \"${_sync_SOURCE_VANITY_URL}\", \"${_sync_TARGET_URL}\"); update wp_revslider_slides set layers = replace(layers, \"${_sync_SOURCE_VANITY_URL}\", \"${_sync_TARGET_URL}\");'";
do 
	_sync_mysqlErrorCount=$(( ${_sync_mysqlErrorCount} + 1 ));
	echo "Attempt #${_sync_mysqlErrorCount}";
	if [ "${_sync_mysqlErrorCount}" -gt "10" ] 
	then 
		throw "Error replacing values";
		exit 1; 
	else 
		echo "trying again in 10s"
		sleep 10; 
	fi; 
done;

# Replace wp_cjtoolbox_template_revisions urls
_sync_mysqlErrorCount=0;
echo 'Replacing wp_cjtoolbox_template_revisions table urls';
until 
	oc exec -i ${_sync_mysqlPod} -- bash -c "mysql -h 10.255.124.80 -u ${_sync_TARGET_USER} -p${_sync_TARGET_PASS} ${_sync_TARGET_DB} -e 'update wp_cjtoolbox_template_revisions set file = replace(file, \"${_sync_SOURCE_URL}\", \"${_sync_TARGET_URL}\"); update wp_cjtoolbox_template_revisions set file = replace(file, \"${_sync_SOURCE_VANITY_URL}\", \"${_sync_TARGET_URL}\");'";
do 
	_sync_mysqlErrorCount=$(( ${_sync_mysqlErrorCount} + 1 ));
	echo "Attempt #${_sync_mysqlErrorCount}";
	if [ "${_sync_mysqlErrorCount}" -gt "10" ] 
	then 
		throw "Error replacing values";
		exit 1; 
	else 
		echo "trying again in 10s"
		sleep 10; 
	fi; 
done;

oc logout
echo "${_sync_SITE} ${_sync_SOURCE_PROJECT} --> ${bamboo_planRepository_branch} Database Sync Complete!";

# read -n 1 -s -r -p "Press any key to continue..."