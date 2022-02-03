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

when all the targets are running we can deploy our scanner 


```
kubectl apply -f https://raw.githubusercontent.com/samma-io/targets/master/base/scanner.yaml
```


### Lets check our scanners.
The scanners will be set to scan the target at a high phase 1 every 5 min. So please check so that your computer can handle the load. If any problems run the delete command bellow.


When we deployed our targets we also deployed some demo scanners that will run


```
kubectl get pods -n samma-io
```

The scanner will deploy many pods that will start scanning 
```
kibana-784b565464-7jx6w                                     1/1     Running     0          21m
nikto-apache-2-4-17-apache-svc-cluster-local--1-rvg2k       0/2     Completed   0          3m51s
nikto-apache-2-4-47-apache-svc-cluster-local--1-tqhmj       0/2     Completed   0          3m41s
nikto-joomla-joomla-svc-cluster-local--1-ftrvd              0/2     Completed   0          3m49s
nikto-mysql-joomla-svc-cluster-local--1-fxwqb               0/2     Completed   0          3m21s
nikto-nginx-1-17-4-nginx-svc-cluster-local--1-2zzp4         0/2     Completed   0          3m19s
nikto-nginx-1-9-5-nginx-svc-cluster-local--1-2nw6w          0/2     Completed   0          3m19s
nikto-phpmyadmin-wordpress-svc-cluster-local--1-r2rmx       0/2     Completed   0          3m18s
nikto-wordpress-wordpress-svc-cluster-local--1-nvkvf        0/2     Completed   0          3m27s
nmap-apache-2-4-17-apache-svc-cluster-local-http--1-4rg2t   0/2     Completed   0          3m59s
nmap-apache-2-4-17-apache-svc-cluster-local-port--1-qbsxk   1/2     Error       0          4m5s
nmap-apache-2-4-17-apache-svc-cluster-local-tls--1-ngq9q    0/2     Completed   0          4m6s
nmap-apache-2-4-47-apache-svc-cluster-local-http--1-5ptfn   0/2     Completed   0          3m53s
nmap-apache-2-4-47-apache-svc-cluster-local-port--1-srbvr   1/2     Error       0          4m3s
nmap-apache-2-4-47-apache-svc-cluster-local-tls--1-gfkz9    0/2     Completed   0          4m6s
nmap-joomla-joomla-svc-cluster-local-http--1-fpmqw          0/2     Completed   0          4m1s
nmap-joomla-joomla-svc-cluster-local-port--1-2jll7          0/2     Completed   0          4m6s
nmap-joomla-joomla-svc-cluster-local-tls--1-w266t           0/2     Completed   0          4m6s
nmap-mysql-joomla-svc-cluster-local-http--1-sb8nr           0/2     Completed   0          3m38s
nmap-mysql-joomla-svc-cluster-local-port--1-gprnj           0/2     Completed   0          3m51s
nmap-mysql-joomla-svc-cluster-local-tls--1-5kpv9            0/2     Completed   0          4m3s
nmap-nginx-1-17-4-nginx-svc-cluster-local-http--1-gpz2l     0/2     Completed   0          3m36s
nmap-nginx-1-17-4-nginx-svc-cluster-local-port--1-fsgjp     0/2     Completed   0          3m51s
nmap-nginx-1-17-4-nginx-svc-cluster-local-tls--1-d8gvw      0/2     Completed   0          4m2s
nmap-nginx-1-9-5-nginx-svc-cluster-local-http--1-299dq      0/2     Completed   0          3m33s
nmap-nginx-1-9-5-nginx-svc-cluster-local-port--1-5jsp5      0/2     Completed   0          3m50s
nmap-nginx-1-9-5-nginx-svc-cluster-local-tls--1-rbcrx       0/2     Completed   0          4m2s
nmap-phpmyadmin-wordpress-svc-cluster-local-http--1-zckzp   0/2     Completed   0          3m33s
nmap-phpmyadmin-wordpress-svc-cluster-local-port--1-t2wkv   0/2     Completed   0          3m50s
nmap-phpmyadmin-wordpress-svc-cluster-local-tls--1-rssvv    0/2     Completed   0          4m2s
nmap-wordpress-wordpress-svc-cluster-local-http--1-zs4mh    0/2     Completed   0          3m40s
nmap-wordpress-wordpress-svc-cluster-local-port--1-4kvwk    0/2     Completed   0          3m53s
nmap-wordpress-wordpress-svc-cluster-local-tls--1-w65zh     0/2     Completed   0          4m2s
proxy-69b4dd8f75-n2grv                                      3/3     Running     0          21m
samma-api-798f86f6d7-p8glj                                  1/1     Running     0          21m
samma-operator-687df768d8-77c79                             1/1     Running     0          21m
```
Let the scan run and you can now go to the next step and look at the result


### If you get into problems remove the scanners with 



```
kubectl delete -f https://raw.githubusercontent.com/samma-io/targets/master/base/apache.yaml
kubectl delete -f https://raw.githubusercontent.com/samma-io/targets/master/base/nginx.yaml
kubectl delete -f https://raw.githubusercontent.com/samma-io/targets/master/base/wordpress.yaml
kubectl delete -f https://raw.githubusercontent.com/samma-io/targets/master/base/joomla.yaml

kubectl delete -f https://raw.githubusercontent.com/samma-io/targets/master/base/scanner.yaml
```