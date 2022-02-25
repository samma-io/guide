# Monitor the Delta
When we are running the our Samma scanner regular. 
We can setup alerts in grafana to monitor if something chnages. To do so we first run a scan to get our baseline. 
When we have our baseline we can set alerts if this changes.

In this example we have a simple baseline where we get alerted if new ports will bo open.
We set an alert to alert us if more than 3 open ports of the same port are open.

You can filter out ports ore calculate the sum in different ways to alert on more changes.


## Alert on changes in the Delta


### The graf
The first thing we need is a dashboard that tracks trends. In Grafana create a new dashboard 


Lets install one of Sammas pre alerts dashbourds

![gui !](assets/grafana4.png)
![gui !](assets/grafana5.png)
![gui !](assets/grafana6.png)
![gui !](assets/grafana7.png)





Add a Alert 

First create a folder that we can add the alert to
![gui !](assets/grafana8.png)






### Set what alerts 
Here we set the levels and what to happen. You can easily search and set different levels of alert to get as close as possible to your baseline.

Go back to the graf in the dashbourd. and click edit.
Now open the tap for alerts and set diffrent values when you want the alert to trigger.



![gui !](assets/grafana10.png)
![gui !](assets/grafana9.png)







