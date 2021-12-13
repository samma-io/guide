# Adding more targets

Now when we have a good base we can add more targets to scans.


## Adidng the targets 
 

 ```
 kubectl apply -f 4-deploy/targets.yaml
 ```


## Than add the scanners

 ```
 kubectl apply -f 4-deploy/scanners.yaml
 ```


## Verify 
Verify that the target and scanners are running 


```
kubectl get all -n targets
kubecrl get all -n samma-io
```


