# Init everything 


In this step we will setup the tools we need to get started.
We will also deploy the scanner and se so that our basic setup is done and working 


### Install minikube
If you have not already done so install minkube and veridy your minikune is working.



https://minikube.sigs.k8s.io/docs/start/


## Deploy the samma tools
Wi will start with deploying the highground into our minikube cluster


```
kubectl create namespace samma-io
kubecte apply -f 1-deploy/highground.yaml
```


## Verigy that the tools are working

```
kubectl get pods -n samma-io
```

You should se our pods are in running state


## Get access to dashbourds
When the pods are running we can get accees to the diffrent dashbourds lets start with grafana


```
minikube service samma-io/grafana
```
This will open your browser and show the grafana. You can login with admin/admin and change the 

And to open the kibana dashbourd you type



```
minikube service samma-io/kibana
```


## No persitant data
So have in mind this minikube and test has no data that will be saved. If the pods ore elasticsearch is killed all data will be gone.