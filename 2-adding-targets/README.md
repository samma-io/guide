## Adding targets 
No its time to add targets that we can scan. And to do that we have some bas targets for you.



### Apply firt targets

Samma has a github repo that has some test targets they be deployd. You can find the targets here 


Samma target repo 

https://github.com/samma-io/targets
```
https://raw.githubusercontent.com/samma-io/targets/master/base/apache.yaml
```


You can also deploy then using github raw
```
kubectl apply -f https://raw.githubusercontent.com/samma-io/targets/master/base/apache.yaml
kubectl apply -f https://raw.githubusercontent.com/samma-io/targets/master/base/nginx.yaml
kubectl apply -f https://raw.githubusercontent.com/samma-io/targets/master/base/wordpress.yaml
kubectl apply -f https://raw.githubusercontent.com/samma-io/targets/master/base/joomla.yaml
```


Now we should have some demo targets into the diffrent namespace. Wait untill all the targets has bean ready and then we can move on to deploy the scanners.

```
kubectl get pods -A 
```


### Lets check our scanners.
The scanners will be set to scan the target at a high phase 1 every 5 min. So please check so that your computer can handle the load. If any problems run the delete command bellow.


When we deployed our targets we also deployed some demo scanners that will run


```
kubectl get pods -n samma-io
```


### If you get into problems remove the scanners with 



```
kubectl delete -f https://raw.githubusercontent.com/samma-io/targets/master/base/apache.yaml
kubectl delete -f https://raw.githubusercontent.com/samma-io/targets/master/base/nginx.yaml
kubectl delete -f https://raw.githubusercontent.com/samma-io/targets/master/base/wordpress.yaml
kubectl delete -f https://raw.githubusercontent.com/samma-io/targets/master/base/joomla.yaml
```