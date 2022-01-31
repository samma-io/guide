## Time to work with the dashbourd


## Samma Api
First lets go to our samma api and look at the scanners we have 

```
minikube service api  -n samma-io
```

Open the browser and look at the api
Here you should see some targets that we added.
You can also delete ore create new targets 

## Grafana

Login into grafana and go to the samma dashboard. (login with admin/admin)


### Task !
Find the following grafs and verify write down the result 


- Number of open ports by nmap
- Number of nikto targets 
- 




### Task 2
Set a alert on number of targets.

- Go to the grafs showing openport over time. 
- Klick to edit that grafs
- Go to alerting
- Set alert to the current value +1 and bellow of the current value -1 

Write down the current value 



## Kibana
Open the kibaan page. 
On of the targets in grafana hade a high port open 33774 lets find out what service was using the high port.


Go to the discover page and search for 33774 look over the result untill you find the target that the port bellong to
Write done that target. 





