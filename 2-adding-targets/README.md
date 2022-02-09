## Adding targets 
No its time to deploy some scanners against targets



### Deploy Scanners

Samma has a Github repo that has some test targets, Thesse targets can be deployed and when they are running we can deploy scanners against the targets,



#### Samma target repo 

https://github.com/samma-io/targets

#### Online Targets
There are also online targets that can be deploys and that scans external server that are hosted by samma.io.




Lets start by deploying the online scanners.

```
kubectl apply -f https://raw.githubusercontent.com/samma-io/targets/master/base/online.yaml
```

### Lets check our scanners.
The scanners will be set to scan the target at a high phase 1 every 5 min. So please check so that your computer can handle the load. If any problems run the delete command bellow.


When we deployed our targets we also deployed some demo scanners that will run


```
kubectl get pods -n samma-io
```

The scanner will deploy many pods that will start scanning 
```
base-braveops-io-base--1-dd74s                  2/2     Running     0          5m33s
elasticsearch-57c4b64bcd-r6k8b                  1/1     Running     0          16m
grafana-7dd7cd6475-b7pxq                        1/1     Running     0          16m
kibana-6759d5cd55-gcd6b                         1/1     Running     0          16m
nikto-bm1-beta-braveops-io--1-559m9             0/2     Completed   0          5m32s
nikto-bm2-beta-braveops-io--1-q5gkq             0/2     Completed   0          5m31s
nikto-bm3-beta-braveops-io--1-g8bg8             0/2     Completed   0          5m32s
nmap-bm1-beta-braveops-io-http--1-hz5gs         0/2     Completed   0          5m32s
nmap-bm1-beta-braveops-io-port--1-9spdn         0/2     Completed   0          5m33s
nmap-bm1-beta-braveops-io-tls--1-zd5l9          0/2     Completed   0          5m33s
nmap-bm2-beta-braveops-io-http--1-f22st         0/2     Completed   0          5m32s
nmap-bm2-beta-braveops-io-port--1-f7lj2         0/2     Completed   0          5m33s
nmap-bm2-beta-braveops-io-tls--1-vq2fj          0/2     Completed   0          5m33s
nmap-bm3-beta-braveops-io-http--1-5jwjz         0/2     Completed   0          5m32s
nmap-bm3-beta-braveops-io-port--1-btxdt         0/2     Completed   0          5m33s
nmap-bm3-beta-braveops-io-tls--1-4w6np          0/2     Completed   0          5m33s
proxy-69b4dd8f75-6kltg                          3/3     Running     0          16m
samma-api-798f86f6d7-frzgs                      1/1     Running     0          16m
samma-operator-79cf75fd9f-vb6cq                 1/1     Running     0          16m
tsunami-bm1-beta-braveops-io-tsunami--1-v9m84   0/3     Completed   0          5m31s
tsunami-bm2-beta-braveops-io-tsunami--1-9c8bd   0/3     Completed   0          5m30s
tsunami-bm3-beta-braveops-io-tsunami--1-j745h   0/3     Completed   0          5m31s
```
Let the scanners run until they are complete.

### Deploy cluster targets
Let's also deploy some in cluster targets to scan.

```
kubectl apply -f https://raw.githubusercontent.com/samma-io/targets/master/base/wordpress.yaml
```

Verify the targets are running before we can deploy the scanners


```
kubectl get pods -n wordpress

NAME                          READY   STATUS    RESTARTS       AGE
mysql-866bcbd66d-wvck9        1/1     Running   1 (21h ago)    22h
phpmyadmin-5f9dc5989f-bdmcq   1/1     Running   1 (21h ago)    22h
wordpress-7f9f98864f-bx2wh    1/1     Running   6 (128m ago)   22h
```
Now lets deploy the scanners


```
kubectl apply -f https://raw.githubusercontent.com/samma-io/targets/master/base/wordpress-scanners.yaml
```

### Targets and scanners 
Now we have deployed samma.io scanners that will scan external targets (Samma.io test targets and domain). We also have deployed some in cluster targets a Wordpress Blog.
And we have also deployed some scanners against that blog.

Now it's time to move on and work with the dashboards and see the result from the scanners.




### If you get into problems remove the scanners with

Sometimes the load of the cluster can be too much and then we need to remove some of the pods to let the cluster recover.

```
kubectl delete -f https://raw.githubusercontent.com/samma-io/targets/master/base/apache.yaml
kubectl delete -f https://raw.githubusercontent.com/samma-io/targets/master/base/nginx.yaml
kubectl delete -f https://raw.githubusercontent.com/samma-io/targets/master/base/wordpress.yaml
kubectl delete -f https://raw.githubusercontent.com/samma-io/targets/master/base/joomla.yaml

kubectl delete -f https://raw.githubusercontent.com/samma-io/targets/master/base/scanner.yaml
```