# Scanboxes
Samma scan boxes are ready to run boxes that you can run to test samma scanners.
Theer are two diffrent types of boxes demobox and scannerbox.

## Demobox
then demo box adds some targets and setup scanner and are uses when you want to test and look around in with the samma scanners.

## Scanner box
The Scannerbox is a standalone scanner. Here you can add your own targets and lunch scans. The sandboxes also have persistence storage that stores the result of the scans.
Then scanner box can be used for a long time.


### VM
Scanner box can be run a VM image ore in a cloud provider. For some cloud providers there are already images provider that you can use to start
ows Scanner box easy.
You can also provision you own using the script provided

### Kubernetes
Scalable scanners. By deploying a scanner box into a Kubernetes cluster you get a full scaling scanning cluster. 
And by adding export of the result with filebeat to example Elasticcloud ore some que you get all full running headless scanning system.






## Get started (both Demo and Scan boxes)
There are many ways to get started with the boxes you can add our build script and build your box from ubuntu 20.04 images.
Our you can lunch a vm from any of our ready images.

You can also lunch Scanboxes from any of the cloud markets places.


### Build your own
Let`s start with building your own to get a better understanding what's inside and what the dieffrent is.
First, you need to have

- Ubuntu 20.04 images
- With 40g of disk
- And 4g of memory (More is good we are to run Elasticsearch and that need some memory)
- SSH access to the box
- Browser to access the box
- This work in bort cloud and on-prem boxes


### Install k8s cluster
The first thing we need to do, Is install the base system and have a k8s cluster up and running.


- Download and run our install file
```
wget https://raw.githubusercontent.com/samma-io/guide/main/scanboxes/ubuntu/setup_k8s_master.sh
```

