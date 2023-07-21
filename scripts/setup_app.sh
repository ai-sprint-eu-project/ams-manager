#!/bin/bash

APP_NAME=""
RETENTION="1d"
NAMESPACE=""
AGENT_INTERVAL="1m"

while getopts a:r:n:i: flag
do
    case "${flag}" in
        a) APP_NAME="${OPTARG}";;
        r) RETENTION="${OPTARG}";;
        n) NAMESPACE="${OPTARG}";;
        i) AGENT_INTERVAL="${OPTARG}";;
    esac
done

if [ -z "$APP_NAME" ]
then
        APP_NAME=`gomplate -c Val=templates/qos_constraints.yaml -i '{{ .Val.system.name }}'`
fi;

if [ -z "$NAMESPACE" ]
then
        NAMESPACE=$APP_NAME
fi;

export BUCKET_NAME="$APP_NAME-bucket"
CONFIGMAP="$APP_NAME-config"
TELEGRAF="$APP_NAME-telegraf"
INFLUX_TOKEN=""
TELEGRAF_PORT=8094

echo "-> $(date) Starting setup $APP_NAME in namespace $NAMESPACE"
echo "-> Params: interval=$AGENT_INTERVAL retention=$RETENTION"

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
	  echo "-> Influx config admin-default not found - cluster monitoring is not configured yet - exit" 
	  exit 1
	fi
}

setup_bucket() {
	if [ `influx bucket list --org ai-sprint --json | grep -c "\"name\": \"$BUCKET_NAME\""` -eq 0 ]; then
          echo "-> Creating bucket ai-sprint/$BUCKET_NAME" 
	  influx bucket create --name $BUCKET_NAME --retention $RETENTION --org ai-sprint
	else
	  echo "-> Bucket ai-sprint/$BUCKET_NAME already exists"
	  BUCKET_ID=`influx bucket ls -n $BUCKET_NAME -o ai-sprint --json | jq -r ".[0].id"`;
	  influx bucket update --id $BUCKET_ID --retention $RETENTION
	fi
}
	    
setup_user() {
    if [ `influx user list --json | grep -c "\"name\": \"$BUCKET_NAME\""` -eq 0 ]; then
        echo "-> Creating user \"$BUCKET_NAME\" in org \"ai-sprint\""
        influx user create --name $BUCKET_NAME --org ai-sprint --json | jq -r ".id"
    else
        echo "-> User $BUCKET_NAME already exists - do nothing"
    fi
}
	    
setup_token() {
	if [ `influx auth list --json | grep -c "\"userName\": \"$BUCKET_NAME\""` -eq 0 ]; then
	  echo "-> Creating token for $BUCKET_NAME"
	  BUCKET_ID=`influx bucket ls -n $BUCKET_NAME -o ai-sprint --json | jq -r ".[0].id"`;
	  INFLUX_TOKEN=`influx auth create --org ai-sprint --read-bucket $BUCKET_ID --write-bucket $BUCKET_ID --user $BUCKET_NAME --json | jq -r ".token"`
	else
	  echo "-> Token for $BUCKET_NAME already exists"
	  INFLUX_TOKEN=`influx auth list --json | jq -r ".[] | select(.userName==\"$BUCKET_NAME\") | .token"`
	fi
	if [ "$(kubectl get configmap $CONFIGMAP -n $NAMESPACE --output name --ignore-not-found)" != "configmap/$CONFIGMAP" ]; then
	  echo "-> Creating configmap $NAMESPACE/$CONFIGMAP"
	  kubectl create configmap $CONFIGMAP --namespace=$NAMESPACE --from-literal=MONIT_HOST=$TELEGRAF --from-literal=MONIT_PORT=$TELEGRAF_PORT --from-literal=MONIT_PROTOCOL=udp
	else
	  echo "Configmap $CONFIGMAP already exists"
	fi 
}

telegraf_dynamic_values() {
INFLUX_NAMESPACE=`kubectl get deployment/ai-sprint-monit-manager -o jsonpath='{.metadata.namespace}'`
echo "env:
  - name: HOSTNAME
    value: \"$TELEGRAF\"
    
config:
  agent:
    interval: \"$AGENT_INTERVAL\"
    round_interval: true
    metric_batch_size: 1000
    metric_buffer_limit: 10000
    collection_jitter: \"0s\"
    flush_interval: \"10s\"
    flush_jitter: \"0s\"
    precision: \"\"
    debug: false
    quiet: false
    logfile: \"\"
    hostname: \"$HOSTNAME\"
    omit_hostname: true
  outputs:
    - influxdb_v2:
        urls: [\"http://ai-sprint-monit-influxdb.$INFLUX_NAMESPACE.svc.cluster.local:8086\"]
        token: \"$INFLUX_TOKEN\"    
        timeout: \"5s\"
        organization: \"ai-sprint\"
        bucket: \"$BUCKET_NAME\"
  inputs:
    - socket_listener:
        service_address: \"udp://:$TELEGRAF_PORT\"
        data_format: \"influx\"
"
}

setup_telegraf() { 
	if [ "$(kubectl get deployment $TELEGRAF -n $NAMESPACE --output name --ignore-not-found)" != "$TELEGRAF" ]; then
	  echo "-> Installing Telegraf release $TELEGRAF"
	  helm install -n $NAMESPACE $TELEGRAF telegraf-1.8.18.tar.gz -f <(telegraf_dynamic_values)
	else
	  echo "-> Telegraf $TELEGRAF already exists"
	fi
}

delete_tasks() {
	echo "-> Removing old alerts"
	TASK_IDS=`influx task ls -o ai-sprint --json | gomplate -d tasks=stdin:///in.json -i '{{ range (ds "tasks") }}{{ if or (strings.Contains "___constraint_check" .name) (strings.Contains "___constraint_notification" .name) (strings.Contains "___throughput" .name) }}{{ .id }} {{end}}{{end}}'`
	for task_id in $TASK_IDS; do influx task delete -id $task_id; done
}

create_alert() {
	echo "-> Creating ${APP_NAME}_${CONSTRAINT_NAME}___constraint_check - template compilation"
	gomplate -f=templates/constraint_check.yaml -o=ccdef.flux -c Val=templates/qos_constraints.yaml -d Params=./params.json
	echo "-> Creating ${APP_NAME}_${CONSTRAINT_NAME}___constraint_check - task create"
	influx task create --file ccdef.flux -o ai-sprint
	echo "-> Creating ${APP_NAME}_${CONSTRAINT_NAME}___constraint_notification - template compilation"
	gomplate -f=templates/constraint_notification.yaml -o=cndef.flux -c Val=templates/qos_constraints.yaml -d Params=./params.json
	echo "-> Creating ${APP_NAME}_${CONSTRAINT_NAME}___constraint_notification - task create"
	influx task create --file cndef.flux -o ai-sprint
}

create_alerts() {
	export GLOBAL_LOCAL=$1
	export APP_NAME
	kubectl get cm monitoring-parameters-cm -o jsonpath="{.data}" > params.json
	echo "-> Creating new alerts for $GLOBAL_LOCAL"
	CONSTRAINT_LIST=`gomplate -c Val=templates/qos_constraints.yaml -i '{{ range $aname, $acontext := (index .Val.system .Env.GLOBAL_LOCAL) }}{{ $aname }} {{end}}'`
    export ALERT_ID=200000
	for cname in $CONSTRAINT_LIST; do
	  export CONSTRAINT_NAME=$cname
	  create_alert
	  export ALERT_ID=$((ALERT_ID+1))
	done
}

create_throughput() {
	export APP_NAME
	echo "-> Creating ${APP_NAME}___throughput - template compilation"
	gomplate -f=templates/throughput_task.yaml -o=ccdef.flux -c Val=templates/qos_constraints.yaml -d Params=./params.json
	echo "-> Creating ${APP_NAME}___throughput - task create"
	influx task create --file ccdef.flux -o ai-sprint
}

create_dashboard() {
	GRAFANA_PASS=`kubectl get secret ai-sprint-monit-grafana -o jsonpath="{.data.admin-password}" | base64 --decode`
	echo "-> Create Grafana temporary token"
	GRAFANA_RESPONSE=`curl -s -X POST -H "Content-Type: application/json" -d '{"name":"tmpkey", "role": "Admin"}' http://admin:$GRAFANA_PASS@ai-sprint-monit-grafana/api/auth/keys`
	GRAFANA_TOKEN=`echo $GRAFANA_RESPONSE | jq -r ".key"`
	GRAFANA_TOKEN_ID=`echo $GRAFANA_RESPONSE | jq -r ".id"`
	export DATASOURCE_UID=`curl -s --insecure -H "Authorization: Bearer $GRAFANA_TOKEN" http://ai-sprint-monit-grafana/api/datasources/name/InfluxDB_v2_Flux | jq -r ".uid"`
	echo "-> Compile Grafana dashboard template with DATASOURCE_UID=$DATASOURCE_UID"
	gomplate -f=templates/constraint_dashboard.json -o=dbdef.json -c Val=templates/qos_constraints.yaml
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
    API_SVC=api/service.yaml
    API_CM=config-map-api.yaml
    API_CM_NX=api/config-map-nginx.yaml
    API_DPL=api/deployment.yaml
    API_SVC_NAME=ai-sprint-monit-api
	echo "-> API deployment update"
    kubectl apply -f $API_SVC
    kubectl apply -f $API_CM
    kubectl apply -f $API_CM_NX
    kubectl get services |\
        grep $API_SVC_NAME 1>/dev/null 2>&1 &&\
        kubectl delete -f $API_DPL
    kubectl create -f $API_DPL
	echo "-> finished API deployment"
    echo
}

check_namespace
check_influxdb_ready
check_influx_config
setup_bucket
setup_user
setup_token
setup_telegraf
api_cm
api
delete_tasks
create_alerts global_constraints
create_alerts local_constraints
create_throughput
create_dashboard

echo "-> $(date) Application setup finished"
