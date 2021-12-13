# Localscanner

With samma you can also run a simple scanner againt any host with a simple docker command.
this is use to verify that a targets could be fixed, Ore to test you applications when you are working with it.

To test start by running this command 


```
docker run sammascanner/tsuname TARGET=test.samma.io
```


In the github pages for every scanner you can fins docker commands for them all. Example are also

```
docker run sammascanner/nmap TARGET=test.samma.io

```


```
docker run sammascanner/nikto TARGET=test.samma.io
```



