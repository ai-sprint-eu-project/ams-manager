#!/bin/bash -e

DEPLOYMENT=ai-sprint-monit-sync
INFLUX_SVC=ai-sprint-monit-influxdb
INFLUX_ORG=ai-sprint
QOS=templates/qos_constraints.yaml
CM_TEMPLATE=sync/config-map.yaml.template
CM=sync/config-map.yaml
SEC_TEMPLATE=sync/secret.yaml.template
SEC=sync/secret.yaml
REMOTE_CFG=remote_influx_sync.yaml
DPL=sync/deployment.yaml

if kubectl get deployments | grep $DEPLOYMENT 1>/dev/null 2>&1; then
    echo 'error: sync already set up!' >&2
    exit 1
fi

echo "-> $(date) setting up Influx sync"

if [ ! -f "$QOS" ]; then
    echo "-> error: no QoS file"
    echo "      Is any application configured?"
    echo
    exit 1
fi

LOCAL_NAME=$(cat $QOS | grep -E '^[[:space:]]+name:' | cut -d: -f2 | xargs)
LOCAL_URL="http:\\/\\/$INFLUX_SVC:8086"
LOCAL_ORG=$INFLUX_ORG
LOCAL_BUCKET="$LOCAL_NAME-bucket"
LOCAL_INFLUX_TOKEN=`kubectl get secret ai-sprint-monit-influxdb -o json \
    | jq -r '.data["admin-user-token"]' \
    | base64 -d - \
    | xargs`
LOCAL_INFLUX_TOKEN_B64=$(echo -n "$LOCAL_INFLUX_TOKEN" | base64)

if [ -z "$LOCAL_NAME" ]; then
    echo "-> error: no local application name"
    echo
    exit 1
fi
if [ -z "$LOCAL_INFLUX_TOKEN" ]; then
    echo "-> error: no local token"
    echo
    exit 1
fi

if [ ! -f "$REMOTE_CFG" ]; then
    echo "-> error: missing remote Influx configuration file"
    echo
    exit 1
fi

REMOTE_URL=$(cat $REMOTE_CFG | grep -E '^[[:space:]]+url:' | awk '{print $2}' | xargs)
REMOTE_URL_S=`echo "$REMOTE_URL" | sed 's/\//\\\\\//g'`
REMOTE_ORG=$(cat $REMOTE_CFG | grep -E '^[[:space:]]+org:' | cut -d: -f2 | xargs)
REMOTE_BUCKET=$(cat $REMOTE_CFG | grep -E '^[[:space:]]+bucket:' | cut -d: -f2 | xargs)
REMOTE_INFLUX_TOKEN=$(cat $REMOTE_CFG | grep -E '^[[:space:]]+token:' | cut -d: -f2 | xargs)
REMOTE_INFLUX_TOKEN_B64=$(echo -n "$REMOTE_INFLUX_TOKEN" | base64)

if [ -z "$REMOTE_URL_S" ]; then
    echo "-> error: no remote URL"
    echo
    exit 1
fi
if [ -z "$REMOTE_ORG" ]; then
    echo "-> error: no remote organisation"
    echo
    exit 1
fi
if [ -z "$REMOTE_BUCKET" ]; then
    echo "-> error: no remote bucket"
    echo
    exit 1
fi
if [ -z "$REMOTE_INFLUX_TOKEN" ]; then
    echo "-> error: no remote token"
    echo
    exit 1
fi

CM_TMP=$(mktemp)
cp $CM_TEMPLATE $CM_TMP
sed -i -e "s/__LOCAL_URL__/$LOCAL_URL/" \
    -e "s/__LOCAL_ORG__/$LOCAL_ORG/" \
    -e "s/__LOCAL_BUCKET__/$LOCAL_BUCKET/" \
    -e "s/__REMOTE_URL__/$REMOTE_URL_S/" \
    -e "s/__REMOTE_ORG__/$REMOTE_ORG/" \
    -e "s/__REMOTE_BUCKET__/$REMOTE_BUCKET/" \
    $CM_TMP
mv $CM_TMP $CM

SEC_TMP=$(mktemp)
cp $SEC_TEMPLATE $SEC_TMP
sed -i -e "s/__LOCAL_TOKEN__/$LOCAL_INFLUX_TOKEN_B64/" \
    -e "s/__REMOTE_TOKEN__/$REMOTE_INFLUX_TOKEN_B64/" \
    $SEC_TMP
mv $SEC_TMP $SEC

for i in "$CM" "$SEC" "$DPL"; do
    kubectl apply -f "$i"
done

echo
echo "-> $(date) successfully finished setting up Influx sync"
