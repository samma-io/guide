## Time to work with the dashbourd


## Grafana
Let's start looking at the Grafana dashboard. We use Grafan to get an overlook of the result of the scanners and to monitor 
if any new problems come up.

Samma provides a Grafana standard dashboard that we use as base and then modified.


Open the dashbourd in minikube


```
 minikube service samma -n samma-io
```
This will open tree taps fins the Grafana tab and login 

**user: samma password: samma-io**

Open the samma dashbourd in grafana

![Grafana first!](/assets/grafana1.png)

### Scanner scanners are based on time

One of the key values in Samma scanner are targat scan is based on time.
So all findings will only be shown for the time you have selected.

This means if you scan a target yesterday and then are looking at the result today, Then the finings of that target will not show.


Here is how you select hos to show the correct time frame.
![Grafana times!](/assets/grafana2.png)



### Lets make a new dashbourd
To make a new dashbourd let find some values that we like. Go to the *explore* page.
- Verify we are using the samma-elasticsearch datasource
- the timeframe are so we have targets.

First lets find all tsunami scanners

![Grafana find!](/assets/grafana3.png)



Know when we have the right scanners lets find all the ports the scanner did find.

![Grafana find!](/assets/grafana4.png)



We also have the port scanner nmap. So lets add all the ports that our nmap scanner did find.


![Grafana both!](/assets/grafana5.png)


Lets add this grafe to our samma.io dashbourd

- Open the dasbourd
- Klick new "Add panel" (righ corner)
- Select "Add new panel"
- Verify the datasource is "Samma-elasticsearch"
- Fill in tha same values as before
- Save

And know we have success search for new values in the scan result, And built a new graf.



To find more points of intrest open the explorer tap and select diffrent fiels. 
(Grafana show all field in elastic and when we choose the scanner typ example tsunami. Then there isn only the fields from the tsunami scanner that will give any result.)






## Kibana
Open the kibaan page. 
On of the targets in grafana hade a high port open 33774 lets find out what service was using the high port.


Go to the discover page and search for 33774 look over the result untill you find the target that the port bellong to
Write done that target. 





