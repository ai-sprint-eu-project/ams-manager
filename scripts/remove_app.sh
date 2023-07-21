#!/bin/bash

NAMESPACE=""
APP_NAME=""

while getopts a:n: flag
do
    case "${flag}" in
        a) APP_NAME="${OPTARG}";;
        n) NAMESPACE="${OPTARG}";;
    esac
done

if [ "$APP_NAME" = "" ]; then
	echo "Usage: remove_app [options] <app_name>"
	echo "Options:"
	echo " -a: application name; required"
	echo " -n: K8S cluser namespace; default: <application name>"
	exit 1;
fi;

echo "-> $(date) Removing setup for $APP_NAME in namespace $NAMESPACE"

BUCKET_NAME="$APP_NAME-bucket"
CONFIGMAP="$APP_NAME-config"
TELEGRAF="$APP_NAME-telegraf"

if [ "$NAMESPACE" = "" ]; then
	NAMESPACE=$APP_NAME
fi;

check_namespace() {
	if [ "$(kubectl get namespace $NAMESPACE -o json | jq -r '.metadata.name')" != "$NAMESPACE" ]; then
		echo "-> Namespace $NAMESPACE not found - exit"
		exit 1
	fi
}

check_influxdb_ready() {
	if [ "$(kubectl get pod -l app.kubernetes.io/name=influxdb -o jsonpath='{.items[0].status.containerStatuses[0].ready}')" = "false" ]; then
		echo "-> InfluxDB is not ready - exit"
		exit 1
	fi
}

check_influx_config() {        
	if [ `influx config list  --json | grep -c "\"admin-default\":"` -eq 0 ]; then
	  echo "-> Influx config admin-default not found - exit" 
	  exit 1
	fi
}

remove_telegraf() {
	if [ "$(helm status $TELEGRAF -n $NAMESPACE 2> /dev/null | grep -c 'STATUS:')" -eq 1 ]; then
		echo "-> Uninstalling Telegraf release $NAMESPACE/$TELEGRAF"
		helm uninstall $TELEGRAF -n $NAMESPACE
	else
		echo "-> Relese $NAMESPACE/$TELEGRAF not found"
	fi
}

remove_token() {
	if [ "$(kubectl get configmap $CONFIGMAP -n $NAMESPACE --output name --ignore-not-found)" = "configmap/$CONFIGMAP" ]; then
		echo "-> Removing configmap $CONFIGMAP"
		kubectl delete configmap $CONFIGMAP --namespace=$NAMESPACE
	else
		echo "-> Configmap $NAMESPACE/$CONFIGMAP not found"
	fi

	TOKEN_ID=`influx auth list --json | jq -r ".[] | select(.userName==\"$BUCKET_NAME\") | .id"`
	if [ $TOKEN_ID ]; then
		echo "-> Removing token"
		influx auth delete --id $TOKEN_ID
	else
		echo "-> Token for $BUCKET_NAME not found"
	fi
}

remove_user() {
	USER_ID=`influx user list --json | jq -r ".[] | select(.name==\"$BUCKET_NAME\") | .id"`
	if [ $USER_ID ]; then
		echo "-> Removing user $BUCKET_NAME"
		influx user delete --id $USER_ID
	else
		echo "-> User $BUCKET_NAME not found"
	fi
}
	    
remove_bucket() {
	BUCKET_ID=`influx bucket ls -n $BUCKET_NAME -o ai-sprint --json 2> /dev/null | jq -r ".[0].id"`;
	if [ $BUCKET_ID ]; then
		echo "-> Removing bucket ai-sprint/$BUCKET_NAME"
		influx bucket delete --id $BUCKET_ID
	else
		echo "-> Bucket ai-sprint/$BUCKET_NAME not found"
	fi
}

delete_alerts() {
	echo "-> Removing old alerts"
	TASK_IDS=`influx task ls -o ai-sprint --json | gomplate -d tasks=stdin:///in.json -i '{{ range (ds "tasks") }}{{ if or (strings.Contains "___constraint_check" .name) (strings.Contains "___constraint_notification" .name) (strings.Contains "___throughput" .name) (strings.Contains "___custom_check" .name) (strings.Contains "___custom_notification" .name) }}{{ .id }} {{end}}{{end}}'`
	for task_id in $TASK_IDS; do influx task delete -id $task_id; done
}

api() {
    API_SVC=api/service.yaml
    API_CM=config-map-api.yaml
    API_CM_NX=api/config-map-nginx.yaml
    API_DPL=api/deployment.yaml
	echo "-> API cleanup"
    kubectl delete -f $API_SVC
    kubectl delete -f $API_CM
    kubectl delete -f $API_CM_NX
    kubectl delete -f $API_DPL
    rm $API_CM
	echo "-> finished API cleanup"
}

./remove_sync.sh
check_namespace
check_influxdb_ready
check_influx_config
api
remove_telegraf
remove_token
remove_user
remove_bucket
delete_alerts

echo "-> $(date) Application setup removal finished"
