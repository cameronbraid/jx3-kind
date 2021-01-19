# jx3-kind
Tool to create a fully self hosted jx3 cluster using [kind](https://kind.sigs.k8s.io/) (kubernetes in docker) and gitea

Requirements (must be pre-installed)
* docker on linux
* sed / tr / cut / base64 / curl

run `./jx3-kind.sh create` will create a single node kubernetes cluster with the following:

* nginx ingress
* gitea (hosting both the cluster repo and demo project)
* minio - for bucketrepo (charts), docker-registry, logs (TODO) and reports (TODO) storage
* vault
* docker-registry-proxy (optional) pull through cache for docker images for speeding up provisioning the cluster
* docker-registry-pull-through-cache (optional) pull through docker registry proxy cache for docker images for speeding up provisioning the cluster
* jenkins-x 3

run `./jx3-kind.sh testDemoApp` will
* use jx project quickstart to create a node-http demo appd
* verify that it is released into staging
* create a PR to change the content
* verify that a new version is released into staging

run `./jx3-kind.sh ci` will do both `create` and `testDemoApp`

run `./jx3-kind.sh destroy` will remove the cluster

## networking

* jx3-kind creates a new docker network `jx3` with subnet `172.21.0.0/16`  To changet this set env `SUBNET` to your subnet and `GATEWAY` to the first IP in the subnet.  The kind control-plane node will use the next IP after `GATEWAY`

## cluster repo

* the cluster repo is cloned from `https://github.com/jx3-gitops-repositories/jx3-kind-vault`
* to have the cluster repo upgraded automatically (using jx gitops upgrade) set `JX_GITOPS_UPGRADE=true`
  
## docker-registry-proxy


Docker Registry Proxy https://github.com/rpardini/docker-registry-proxy

* Essentially, it's a man in the middle: an intercepting proxy based on nginx, to which all docker traffic is directed using the HTTPS_PROXY mechanism and injected CA root certificates
* Caches images from any registry. Caches the potentially huge blob/layer requests (for bandwidth/time savings), and optionally caches manifest requests ("pulls") to avoid rate-limiting.

* `DOCKER_REGISTRY_PROXY_HOST=XXX ./jx3-kind.sh startDockerRegistryProxy` will run a local docker-registry-proxy container - replace XXX with your host ip (see other config options at the top of jx3-kind.sh)
* `DOCKER_REGISTRY_PROXY_HOST=XXX DOCKER_REGISTRY_PROXY=true ./jx3-kind.sh ci` to run the `ci` using the local proxy

Doesn't support pushing images - which is fine in kind since the container runtime on the 'host' never needs to push.

## docker-registry-pull-through-cache

* The docker registry pull through cache is a `registry:2` container which will be used by kaniko to speed up building images.
* It only works for docker.io images.
* docker-registry-proxy can't be used for kaniko because it doesnt support pushing images (though work is happening on this front)


## Why ?

* To identify (and assist in fixing) bugs in jx3 related to gitea
* To enable me to gain a deeper understanding of jx3 both how it works and how it is configured
* To provide a CI test for jx3