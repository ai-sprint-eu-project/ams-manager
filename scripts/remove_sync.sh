#!/bin/bash
NAME=ai-sprint-monit-sync
echo "-> $(date) Removing previously configured Influx sync, if exists"
for i in deployment configmap secret; do
    kubectl delete "$i" "$NAME"
done
echo
