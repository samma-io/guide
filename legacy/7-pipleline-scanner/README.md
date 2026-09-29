# Running scans in the pipline 


One task is to have a pipeline to run and to add scanner into your cluster.


## Version control targets
Using a pipeline to control you targets mean you can have a git repo with your targets in a simple file.
When new targets are added to the file. The CI/CD tools kicks in and deploy scanners againts the new targets.
In most CI/CD tools you can also setup schedules task to performe regular scans against targets


## Gitlab
Here we use a CI/CD till called gitlab. We will setup a gitlrepo that holdes a targets file. 
And then new targets is added we will run the pipeline and deploy scanners againts the new targets


### Example repo
You will fins the code that we use in this repo

https://github.com/samma-io/targets/tree/master/pipeline/gitlab


### 