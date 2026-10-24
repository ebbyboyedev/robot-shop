#!/bin/sh
helm install robot-shop ./K8s/helm --namespace robot-shop --create-namespace
kubectl apply -f K8s/load-deployment.yaml -n robot-shop