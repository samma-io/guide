#!/bin/bash
#
# Script to deploy and apply samma tools and to keep them updated
#
# Need kubectl access to run
#
export KUBECONFIG=/etc/kubernetes/admin.conf
echo "Deploy samma Base"
kubectl apply -f https://raw.githubusercontent.com/samma-io/operator/main/manifest/samma-operator.yaml



echo "Deploy the highground"
kubectl apply -f https://raw.githubusercontent.com/samma-io/guide/main/1-init/1-deploy/highground.yaml