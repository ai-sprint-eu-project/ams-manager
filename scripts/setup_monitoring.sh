#!/bin/bash

TELEGRAF_CM="ai-sprint-monit-telegraf-ds"
MONITORING_CM="monitoring-parameters-cm"
RESTART="true"

while getopts r: flag
do
    case "${flag}" in
        r) RESTART="${OPTARG}";;
    esac
done

echo "-> $(date) Starting monitoring setup"

# Check if Telegtaf daemonset config map exists
if [ "$(kubectl get configmap $TELEGRAF_CM --output name --ignore-not-found)" != "configmap/$TELEGRAF_CM" ]; then
	echo "-> Error: Configmap $TELEGRAF_CM does not exist - exit"
	exit 1
fi

compile_config() {
	# Prepare new config
	echo "-> Compile template $2"
	gomplate -f=templates/$2 -o=cmdef.yaml -c Val=templates/monitoring_setup.yaml
	echo "-> Get old config $1"
	kubectl get configmap $1 -o yaml > cmtmp.yaml
	echo "-> Trim old config"
	LINE="`cat cmtmp.yaml | grep -n "kind: ConfigMap" | cut -f1 -d:`"
	tail cmtmp.yaml -n +$LINE >> cmdef.yaml
	# Apply new config
	echo "-> Apply new config $1"
	kubectl apply -f cmdef.yaml
}

compile_config $MONITORING_CM "monitoring_config_map.yaml"
compile_config $TELEGRAF_CM "telegraf_config_map.yaml"

if [ "$RESTART" = "true" ]; then
	# Restart daemonset
	echo "-> Restart daemonset"
	kubectl rollout restart daemonset/ai-sprint-monit-telegraf-ds
else
	echo "-> Daemonset restart ommited"
fi

delete_alerts() {
	echo "-> Removing old alerts"
	TASK_IDS=`influx task ls -o ai-sprint --json | gomplate -d tasks=stdin:///in.json -i '{{ range (ds "tasks") }}{{ if or (strings.Contains "___alert_check" .name) (strings.Contains "___alert_notification" .name) }}{{ .id }} {{end}}{{end}}'`
	for task_id in $TASK_IDS; do influx task delete -id $task_id; done
}

create_alert() {
	echo "-> Creating alert $ALERT_NAME - check template compilation"
	gomplate -f=templates/alert_check.yaml -o=acdef.flux -c Val=templates/monitoring_setup.yaml
	echo "-> Creating alert $ALERT_NAME - check task create"
	influx task create --file acdef.flux -o ai-sprint
	echo "-> Creating alert $ALERT_NAME - notification template compilation"
	gomplate -f=templates/alert_notification.yaml -o=andef.flux -c Val=templates/monitoring_setup.yaml
	echo "-> Creating alert $ALERT_NAME - notification task create"
	influx task create --file andef.flux -o ai-sprint
}

create_alerts() {
	echo "-> Creating new alerts"
	ALERT_LIST=`gomplate -c Val=templates/monitoring_setup.yaml -i '{{if has .Val.monitoring "alerts"}}{{ range $aname, $acontext := .Val.monitoring.alerts }}{{ $aname }} {{end}}{{end}}'`
    export ALERT_ID=100000
	for aname in $ALERT_LIST; do
	  export ALERT_NAME=$aname
	  create_alert
	  export ALERT_ID=$((ALERT_ID+1))
	done
}

create_dashboard() {
	kubectl get nodes -o json | jq -r '[.items[].metadata.name]' > nodes.json
	GRAFANA_PASS=`kubectl get secret ai-sprint-monit-grafana -o jsonpath="{.data.admin-password}" | base64 --decode`
	echo "-> Create Grafana temporary token"
	GRAFANA_RESPONSE=`curl -s -X POST -H "Content-Type: application/json" -d '{"name":"tmpkey", "role": "Admin"}' http://admin:$GRAFANA_PASS@ai-sprint-monit-grafana/api/auth/keys`
	GRAFANA_TOKEN=`echo $GRAFANA_RESPONSE | jq -r ".key"`
	GRAFANA_TOKEN_ID=`echo $GRAFANA_RESPONSE | jq -r ".id"`
	export DATASOURCE_UID=`curl -s --insecure -H "Authorization: Bearer $GRAFANA_TOKEN" http://ai-sprint-monit-grafana/api/datasources/name/InfluxDB_v2_Flux | jq -r ".uid"`
	echo "-> Compile Grafana dashboard template with DATASOURCE_UID=$DATASOURCE_UID"
	gomplate -f=templates/monitoring_dashboard.json -o=dbdef.json -c Val=templates/monitoring_setup.yaml -d Nodes=./nodes.json
	echo "-> Create/update Grafana dashboard"
    curl -s -X POST --insecure -H "Authorization: Bearer $GRAFANA_TOKEN" -H "Content-Type: application/json" --data "@dbdef.json" http://ai-sprint-monit-grafana/api/dashboards/db
	echo " "
	echo "-> Delete Grafana temporary token"
	curl -s -X DELETE -H "Content-Type: application/json" -d '{}' http://admin:$GRAFANA_PASS@ai-sprint-monit-grafana/api/auth/keys/$GRAFANA_TOKEN_ID
	echo " "
}

api_cm() {
    CM_TEMPLATE=api/config-map-api.yaml.template
    CM=config-map-api.yaml
    QOS=templates/qos_constraints.yaml
	echo "-> compiling API configmap"
    INFLUX_TOKEN=`kubectl get secret ai-sprint-monit-influxdb -o json \
        | jq -r '.data["admin-user-token"]' \
        | base64 -d - \
        | xargs`
    WINDOW=$(jq .performance_metrics_time_window_width params.json | xargs)
    NAME=$(cat $QOS | grep -E '^[[:space:]]+name:' | cut -d: -f2 | xargs)
    [ x$INFLUX_TOKEN = x ] && {
        echo "-> error: no Influx token"
        echo
        return
    }
    [ x$WINDOW = x -o x$NAME = x ] && {
        echo "-> error: \$WINDOW=\"$WINDOW\" \$NAME=\"$NAME\""
        echo
        return
    }
    CM_TMP=$(mktemp)
    BUCKET="$NAME-bucket"
    cp $CM_TEMPLATE $CM_TMP
    sed -i -e "s/__TOKEN__/$INFLUX_TOKEN/" \
        -e "s/__WINDOW__/$WINDOW/" \
        -e "s/__BUCKET__/$BUCKET/" \
        $CM_TMP
    mv -v $CM_TMP $CM
	echo "-> done compiling API configmap"
    echo
}

api() {
    API_CM=config-map-api.yaml
    API_DPL=api/deployment.yaml
    API_SVC_NAME=ai-sprint-monit-api
    kubectl get services |\
            grep $API_SVC_NAME 1>/dev/null 2>&1 && {
        echo "-> API deployment update"
        api_cm
        [ -f "$API_CM" ] || return
        kubectl apply -f $API_CM
        kubectl delete -f $API_DPL
        kubectl create -f $API_DPL
        echo "-> finished API deployment"
        echo
    }
}

api
delete_alerts
create_alerts
create_dashboard

echo "-> $(date) Setup finished"
