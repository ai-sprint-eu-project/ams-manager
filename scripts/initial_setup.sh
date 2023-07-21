#!/bin/bash

echo "-> $(date) Starting initial monitoring setup"

wait_for_influxdb_ready() {
	echo -n "-> Waiting for influxdb POD to be ready: "
	for i in $(seq 1 120) 
	do 
		echo -n "." 
		if [ "$(kubectl get pod -l app.kubernetes.io/name=influxdb -o jsonpath='{.items[0].status.containerStatuses[0].ready}')" = "true" ]; then
			echo "Ready"
			sleep 5
			return
		fi 
		sleep 5
	done 
	echo "waiting timeout"
	exit 1
}

recreate_influx_config() {        
	if [ `influx config list  --json | grep -c "\"admin-default\":"` -ne 0 ]; then
	  echo "-> Removing existing influx config" 
	  influx config rm admin-default
	fi
	INFLUX_TOKEN=`kubectl get secret ai-sprint-monit-influxdb -o jsonpath="{.data.admin-user-token}" | base64 -d`
    echo "-> Creating influx config" 
	influx config create --config-name admin-default --host-url http://ai-sprint-monit-influxdb:8086 --org primary --token $INFLUX_TOKEN --active
}

create_organization() {
	if [ `influx org list --json | grep -c "\"name\": \"ai-sprint\""` -eq 0 ]; then
          echo "-> Creating organization ai-sprint" 
	  influx org create --name ai-sprint --description "AI-Sprint Monitoring organization"
	else
	  echo "-> Organization ai-sprint already exists - do nothing"
	fi
}
	    
create_bucket() {
	if [ `influx bucket list --org ai-sprint --json | grep -c "\"name\": \"ai-sprint-monit\""` -eq 0 ]; then
          echo "-> Creating bucket ai-sprint/ai-sprint-monit" 
	  influx bucket create --name ai-sprint-monit --retention 1d --org ai-sprint
	else
	  echo "-> Bucket ai-sprint/ai-sprint-monit already exists - do nothing"
	fi
}
	    
create_user() {
    if [ `influx user list --json | grep -c "\"name\": \"ai-sprint-monit\""` -eq 0 ]; then
        echo '-> Creating user "ai-sprint-monit" in org "ai-sprint"'
        influx user create --name ai-sprint-monit --org ai-sprint --json | jq -r ".id"
    else
        echo "-> User ai-sprint-monit already exists - do nothing"
    fi
}
	    
create_token() {
    MONIT_TOKEN=""
	if [ `influx auth list --json | grep -c "\"userName\": \"ai-sprint-monit\""` -eq 0 ]; then
	  echo "-> Creating token for ai-sprint-monit"
	  MONIT_BUCKET_ID=`influx bucket ls -n ai-sprint-monit -o ai-sprint --json | jq -r ".[0].id"`; 
	  MONIT_TOKEN=`influx auth create --org ai-sprint --read-buckets --write-bucket $MONIT_BUCKET_ID --user ai-sprint-monit --json | jq -r ".token"`
	else
	  echo "-> Token for ai-sprint-monit already exists - check configmap"
	  MONIT_TOKEN=`influx auth list --json | jq -r '.[] | select(.userName=="ai-sprint-monit") | .token'`
	  if [ "$(kubectl get configmap/influxdb-cm -o jsonpath='{.data.monitToken}')" = "$MONIT_TOKEN" ]; then
		echo "-> Configmap already configured"
		return
	  fi 
	fi
		 
	echo "-> Setup INFLUX_TOKEN for telegraf/grafana"
	kubectl patch configmap/influxdb-cm --type merge -p "{\"data\":{\"monitToken\":\"$MONIT_TOKEN\"}}"
}

setup_monitoring() {
	./setup_monitoring.sh -r "false"
}

allow_pods() {
	echo "-> Allow telegraf/grafana PODs scheduling"
	kubectl patch daemonset/ai-sprint-monit-telegraf-ds --type=json -p='[{"op": "remove", "path": "/spec/template/spec/nodeSelector/do-not"}]'
	kubectl patch deployment/ai-sprint-monit-grafana --type=json -p='[{"op": "remove", "path": "/spec/template/spec/nodeSelector/do-not"}]'
	kubectl rollout restart deployment/ai-sprint-monit-grafana
}

wait_for_influxdb_ready
recreate_influx_config
create_organization
create_bucket
create_user
create_token
setup_monitoring
allow_pods

echo "-> Starting eternal loop"
while [ 1 ]; do sleep 1000; done
