#!/bin/bash

APP_NAME=""

while getopts a: flag
do
    case "${flag}" in
        a) APP_NAME="${OPTARG}";;
    esac
done

if [ -z "$APP_NAME" ]
then
        APP_NAME=`gomplate -c Val=templates/custom_setup.yaml -i '{{ .Val.monitoring.name }}'`
fi;

echo "-> $(date) Starting custom setup $APP_NAME in namespace $NAMESPACE"

delete_alerts() {
	echo "-> Removing old alerts"
	TASK_IDS=`influx task ls -o ai-sprint --json | gomplate -d tasks=stdin:///in.json -i '{{ range (ds "tasks") }}{{ if or (strings.Contains "___custom_check" .name) (strings.Contains "___custom_notification" .name) }}{{ .id }} {{end}}{{end}}'`
	for task_id in $TASK_IDS; do influx task delete -id $task_id; done
}

create_alert() {
	echo "-> Creating ${APP_NAME}_${CUSTOM_NAME}___custom_check - template compilation"
	gomplate -f=templates/custom_check.yaml -o=ccdef.flux -c Val=templates/custom_setup.yaml
	echo "-> Creating ${APP_NAME}_${CUSTOM_NAME}___custom_check - task create"
	influx task create --file ccdef.flux -o ai-sprint
	echo "-> Creating ${APP_NAME}_${CUSTOM_NAME}___custom_notification - template compilation"
	gomplate -f=templates/custom_notification.yaml -o=cndef.flux -c Val=templates/custom_setup.yaml
	echo "-> Creating ${APP_NAME}_${CUSTOM_NAME}___custom_notification - task create"
	influx task create --file cndef.flux -o ai-sprint
}

create_alerts() {
	export APP_NAME
	echo "-> Creating new custom alerts"
	CUSTOM_LIST=`gomplate -c Val=templates/custom_setup.yaml -i '{{- if has .Val.monitoring "alerts" -}}{{ range $aname, $acontext := (index .Val.monitoring.alerts ) }}{{ $aname }} {{end}}{{end}}'`
    export ALERT_ID=300000
	for cname in $CUSTOM_LIST; do
	  export CUSTOM_NAME=$cname
	  create_alert
	  export ALERT_ID=$((ALERT_ID+1))
	done
}

create_dashboard() {
	GRAFANA_PASS=`kubectl get secret ai-sprint-monit-grafana -o jsonpath="{.data.admin-password}" | base64 --decode`
	echo "-> Create Grafana temporary token"
	GRAFANA_RESPONSE=`curl -s -X POST -H "Content-Type: application/json" -d '{"name":"tmpkey", "role": "Admin"}' http://admin:$GRAFANA_PASS@ai-sprint-monit-grafana/api/auth/keys`
	GRAFANA_TOKEN=`echo $GRAFANA_RESPONSE | jq -r ".key"`
	GRAFANA_TOKEN_ID=`echo $GRAFANA_RESPONSE | jq -r ".id"`
	export DATASOURCE_UID=`curl -s --insecure -H "Authorization: Bearer $GRAFANA_TOKEN" http://ai-sprint-monit-grafana/api/datasources/name/InfluxDB_v2_Flux | jq -r ".uid"`
	echo "-> Compile Grafana custom dashboard template with DATASOURCE_UID=$DATASOURCE_UID"
	gomplate -f=templates/custom_dashboard.json -o=dbdef.json -c Val=templates/custom_setup.yaml
	echo "-> Create/update Grafana custom dashboard"
    curl -s -X POST --insecure -H "Authorization: Bearer $GRAFANA_TOKEN" -H "Content-Type: application/json" --data "@dbdef.json" http://ai-sprint-monit-grafana/api/dashboards/db
	echo " "
	echo "-> Delete Grafana temporary token"
	curl -s -X DELETE -H "Content-Type: application/json" -d '{}' http://admin:$GRAFANA_PASS@ai-sprint-monit-grafana/api/auth/keys/$GRAFANA_TOKEN_ID
	echo " "
}

delete_alerts
create_alerts
create_dashboard

echo "-> $(date) Application custom setup finished"
