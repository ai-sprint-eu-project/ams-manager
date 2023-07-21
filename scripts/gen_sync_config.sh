#!/bin/bash -e

INFLUX_ORG=ai-sprint
QOS=templates/qos_constraints.yaml
CFG_TEMPLATE=sync/influx_sync.yaml.template
CFG=influx_sync.yaml

echo "-> $(date) generating Influx sync config"

if [ ! -f "$QOS" ]; then
    echo "-> error: no QoS file"
    echo "      Is any application configured?"
    echo
    exit 1
fi

LOCAL_NAME=$(cat $QOS | grep -E '^[[:space:]]+name:' | cut -d: -f2 | xargs)
LOCAL_BUCKET="$LOCAL_NAME-bucket"
LOCAL_INFLUX_TOKEN=`kubectl get secret ai-sprint-monit-influxdb -o json \
    | jq -r '.data["admin-user-token"]' \
    | base64 -d - \
    | xargs`

if [ -z "$LOCAL_NAME" ]; then
    echo "-> error: no local application name"
    echo
    exit 1
fi
if [ -z "$LOCAL_INFLUX_TOKEN" ]; then
    echo "-> error: no local Influx token"
    echo
    exit 1
fi

CFG_TMP=$(mktemp)
cp $CFG_TEMPLATE $CFG_TMP
sed -i -e "s/__ORG__/$INFLUX_ORG/" \
    -e "s/__TOKEN__/$LOCAL_INFLUX_TOKEN/" \
    -e "s/__BUCKET__/$LOCAL_BUCKET/" \
    $CFG_TMP
mv $CFG_TMP $CFG

echo
echo '==============================================================================='
cat $CFG
echo '==============================================================================='
echo

echo "-> $(date) successfully finished generating Influx sync config"
