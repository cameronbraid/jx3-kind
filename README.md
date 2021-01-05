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
* docker-registry-proxy (optional) pull through cache for docker images for speeding up provisioning the cluster

run `./jx3-kind.sh testProjectGitops` will
* node-http demo app
* verify that it is released into staging
* create a PR to change the content
* verify that a new version is released into staging

run `./jx3-kind.sh ci` will do both `create` and `testProjectGitops`

run `./jx3-kind.sh destroy` will remove the cluster

## docker-registry-proxy

* run `DOCKER_REGISTRY_PROXY_HOST=XXX ./jx3-kind.sh startDockerRegistryProxy` will run a local docker-registry-proxy container - replace XXX with your host ip (see other config options at the top of jx3-kind.sh)
* run `DOCKER_REGISTRY_PROXY_HOST=XXX DOCKER_REGISTRY_PROXY=true ./jx3-kind.sh ci` to run the `ci` using the local proxy