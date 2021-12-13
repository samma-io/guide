## Adding targets 
No its time to add targets that we can scan. And to do that we have some bas targets for you.



### Apply firt targets

```
kubectl create namespace targets
kubectl apply -f 2-target/target.yaml
```

This will deploy a list of targets into the target namespace. Wait untill all the targets has bena ready and then we can move on to deploy the scanners.


```
kubectl get pods -n targets
```


### Lets apply our scanners.
The scanners will be set to scan the target at a high phase 1 every 5 min. So please check so that your computer can handle the load. If any problems run the delete command bellow.


Lets install the scanners

```
kubectl apply -f 2-target/scanner.yaml
```

Verify that the scanners have started with this command


```
kubectl get pods -n samma-io
```


### If you get into problems remove the scanners with 


```
kubectl apply -f 2-target/delete.yaml
```
