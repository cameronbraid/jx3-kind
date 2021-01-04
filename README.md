# jx3-kind
Tool to create a fully self hosted jx3 cluster using [kind](https://kind.sigs.k8s.io/) (kubernetes in docker) and gitea

Requirements (must be pre-installed)
* docker on linux
* kubectl
* jx3 cli
* sed

run `./jx3-kind.sh create` will create a single node kubernetes cluster with the following:

* nginx ingress
* gitea (hosting both the cluster repo and demo project)
* minio - for bucketrepo (charts), docker-registry, logs (TODO) and reports (TODO) storage
* vault
* jenkins-x 3
* node-http demo app
* docker-registry-proxy (optional) pull through cache for docker images for speeding up provisioning the cluster


run `./jx3-kind.sh destroy` will remove the cluster