#!/usr/bin/env bash
# https://stackoverflow.com/questions/2336977/can-a-shell-script-indicate-that-its-lines-be-loaded-into-memory-initially
{
set -euo pipefail 

COMMAND=${1:-'help'}

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

ORG="${ORG:-coders}"
DEVELOPER_USER="${DEVELOPER_USER:-developer}"
DEVELOPER_PASS="${DEVELOPER_PASS:-developer}"
BOT_USER="${BOT_USER:-jx3-bot}"
BOT_PASS="${BOT_PASS:-jx3-bot}"
SUBNET=${SUBNET:-"172.21.0.0/16"}
GATEWAY=${GATEWAY:-"172.21.0.1"}
JX_GITOPS_UPGRADE=${JX_GITOPS_UPGRADE:-"false"}
LOG=${LOG:-"file"} #or console
GITEA_ADMIN_PASSWORD=${GITEA_ADMIN_PASSWORD:-"abcdEFGH"}
LIGHTHOUSE_VERSION=${LIGHTHOUSE_VERSION:-"0.0.900"}


# if docker-registry-proxy should be used
DOCKER_REGISTRY_PROXY=${DOCKER_REGISTRY_PROXY:-"false"}

# the address of the docker-registry-proxy
# when running the dockerRegistryProxy comand this is the IP of the docker host and the port on the host to forward to the container
DOCKER_REGISTRY_PROXY_HOST=${DOCKER_REGISTRY_PROXY_HOST:-"192.168.0.101"}
DOCKER_REGISTRY_PROXY_PORT=${DOCKER_REGISTRY_PROXY_PORT:-"3128"}

# configuration for docker-registry-proxy
DOCKER_REGISTRY_PROXY_REGISTRIES=${DOCKER_REGISTRY_PROXY_REGISTRIES:-"k8s.gcr.io gcr.io quay.io registry.opensource.zalan.do"}
DOCKER_REGISTRY_PROXY_AUTH_REGISTRIES=${DOCKER_REGISTRY_PROXY_AUTH_REGISTRIES:-""}

# when using command dockerRegistryProxy to start the proxy, the configures the container name and local storage folder for cache data
DOCKER_REGISTRY_PROXY_CONTAINER_NAME=${DOCKER_REGISTRY_PROXY_CONTAINER_NAME:-"docker-registry-proxy"}
DOCKER_REGISTRY_PROXY_CACHE_FOLDER=${DOCKER_REGISTRY_PROXY_CACHE_FOLDER:-"/media/data-ssd/dev-kube/docker-registry-proxy"}


# thanks https://stackoverflow.com/questions/33056385/increment-ip-address-in-a-shell-script#43196141
nextip(){
  IP=$1
  IP_HEX=$(printf '%.2X%.2X%.2X%.2X\n' `echo $IP | sed -e 's/\./ /g'`)
  NEXT_IP_HEX=$(printf %.8X `echo $(( 0x$IP_HEX + 1 ))`)
  NEXT_IP=$(printf '%d.%d.%d.%d\n' `echo $NEXT_IP_HEX | sed -r 's/(..)/0x\1 /g'`)
  echo "$NEXT_IP"
}
IP=`nextip $GATEWAY`

declare -a CURL_AUTH=()
curlBasicAuth() {
  username=$1
  password=$2
  basic=`echo -n "${username}:${password}" | base64`
  CURL_AUTH=("-H" "Authorization: Basic $basic")
}
curlTokenAuth() {
  token=$1
  CURL_AUTH=("-H" "Authorization: token ${token}")
}

GIT_SCHEME="http"
GIT_HOST="gitea.${IP}.nip.io"
GIT_URL="${GIT_SCHEME}://${GIT_HOST}"
curlBasicAuth "gitea_admin" "${GITEA_ADMIN_PASSWORD}"
CURL_GIT_ADMIN_AUTH=("${CURL_AUTH[@]}")
declare -a CURL_TYPE_JSON=("-H" "Accept: application/json" "-H" "Content-Type: application/json")
# "${GIT_SCHEME}://gitea_admin:${GITEA_ADMIN_PASSWORD}@${GIT_HOST}"

if [[ "${LOG}" == "file" && "${COMMAND}" != "env" ]]; then
  # https://unix.stackexchange.com/questions/462156/how-do-i-find-the-line-number-in-bash-when-an-error-occured#462157
  # redirect 4 to stderr and 3 to stdout 
  exec 3>&1 4>&2
  # restore file desciptors
  trap 'exec 2>&4 1>&3; err' 1 2 3
  trap 'exec 2>&4 1>&3;' 0
  # redirect original stdout to log file
  exec 1>log
else
  trap 'err' ERR
fi

# write message to console and log
info() {
  if [[ "${LOG}" == "file" ]]; then
    echo -e "$@" >&3
    echo -e "$@"
  else
    echo -e "$@"
  fi
}

# write to console and store some information for error reporting
STEP=""
SUB_STEP=""
step() {
  STEP="$@"
  SUB_STEP=""
  info 
  info "[$STEP]"
}
# store some additional information for error reporting
substep() {
  SUB_STEP="$@"
  info " - $SUB_STEP"
}

err() {
  if [[ "$STEP" == "" ]]; then
      echo "Failed running: ${BASH_COMMAND}"
  else
    if [[ "$SUB_STEP" != "" ]]; then
      echo "Failed at [$STEP / $SUB_STEP] running : ${BASH_COMMAND}"
    else
      echo "Failed at [$STEP] running : ${BASH_COMMAND}"
    fi
  fi
}

FILE_BUCKETREPO_VALUES=`cat <<'EOF'
envSecrets:
  AWS_ACCESS_KEY: "" # use secret-mapping to map from vault
  AWS_SECRET_KEY: "" # use secret-mapping to map from vault
EOF
`

FILE_KIND_NODE_IMAGE_HTTP_PROXY_CONF=`cat <<EOF
[Service]
Environment="HTTP_PROXY=http://${DOCKER_REGISTRY_PROXY_HOST}:${DOCKER_REGISTRY_PROXY_PORT}/"
Environment="HTTPS_PROXY=http://${DOCKER_REGISTRY_PROXY_HOST}:${DOCKER_REGISTRY_PROXY_PORT}/"
Environment="NO_PROXY=localhost,docker-registry-jx.${IP}.nip.io,minio-jx.${IP}.nip.io"
EOF
`

FILE_KIND_NODE_IMAGE_DOCKERFILE=`cat <<EOF
FROM kindest/node:v1.19.1
ADD http://${DOCKER_REGISTRY_PROXY_HOST}:${DOCKER_REGISTRY_PROXY_PORT}/ca.crt /usr/share/ca-certificates/docker_registry_proxy.crt
RUN echo "docker_registry_proxy.crt" >> /etc/ca-certificates.conf && \
    update-ca-certificates --fresh && \
    mkdir -p /etc/systemd/system/containerd.service.d/
COPY http-proxy.conf /etc/systemd/system/containerd.service.d/
EOF
`

FILE_DOCKER_REGISTRY_VALUES_YAML_GOTMPL=`cat <<'EOF'
# https://github.com/helm/charts/blob/master/stable/docker-registry/values.yaml
#
# NOTE: the chart is deprecated
#

# for filesystem persistence
# persistence: 
#   enabled: true

storage: s3
s3:
  
  region: unused
  regionEndpoint: http://minio{{ .Values.jxRequirements.ingress.namespaceSubDomain }}{{ .Values.jxRequirements.ingress.domain }}
  bucket: jx3
  encrypt: false
  secure: false
  # not supported in chart, have to use configData.storage.s3 below
  # rootdirectory: docker-registry
secrets:
  s3:
    accessKey: "x" # will be replaced by ExternalSecret
    secretKey: "x" # will be replaced by ExternalSecret

configData:
  version: 0.1
  log:
    fields:
      service: registry
  storage:
    cache:
      blobdescriptor: inmemory
    s3:
      # https://docs.docker.com/registry/storage-drivers/s3/
      rootdirectory: /docker-registry
  http:
    addr: :5000
    headers:
      X-Content-Type-Options: [nosniff]
  health:
    storagedriver:
      enabled: true
      interval: 10s
      threshold: 3
EOF
`

FILE_GITEA_VALUES_YAML=`cat <<EOF
ingress:
  enabled: true
  annotations:
    kubernetes.io/ingress.class: nginx
  hosts:
    - gitea.${IP}.nip.io
gitea:
  admin:
    password: ${GITEA_ADMIN_PASSWORD}
  config:
    database:
      DB_TYPE: sqlite3
      ## Note that the intit script checks to see if the IP & port of the database service is accessible, so make sure you set those to something that resolves as successful (since sqlite uses files on disk setting the port & ip won't affect the running of gitea).
      HOST: ${IP}:80 # point to the nginx ingress
    service:
      DISABLE_REGISTRATION: true
  database:
    builtIn:
      postgresql:
        enabled: false
image:
  version: 1.13.0
EOF
`

FILE_JX_BUILD_CONTROLLER_VALUES_YAML=`cat << 'EOF'
# image:
#   repository: gcr.io/jenkinsxio/jx-build-controller
#   tag: "0.0.20"
EOF
`

FILE_KPT_STRATEGY_YAML=`cat << 'EOF'
config:
  - relativePath: versionStream
    strategy: resource-merge
EOF
`


FILE_MINIO_SECRET_SCHEMA_YAML==`cat << EOF
apiVersion: gitops.jenkins-x.io/v1alpha1
kind: Schema
spec:
  objects:
  - name: minio
    mandatory: true
    properties:
    - name: accesskey
      question: minio accesskey
      help: The accesskey for minio authentication
      defaultValue: minio
    - name: secretkey
      question: minio secretkey
      help: The secretkey for minio authentication
      defaultValue: minio123
EOF
`
FILE_MINIO_VALUES_YAML_GOTMPL=`cat << 'EOF'
# https://helm.min.io/

# these are overriden by the values in vault
accessKey: "x"
secretKey: "x"

ingress:
  enabled: true
  hosts:
  - minio{{ .Values.jxRequirements.ingress.namespaceSubDomain }}{{ .Values.jxRequirements.ingress.domain }}

buckets:
  - name: jx3
    policy: none
    purge: false
EOF
`

FILE_JX_LIGTHHOUSE_VALUES_YAML=`cat << EOF
# https://github.com/jenkins-x/lighthouse/blob/master/charts/lighthouse/values.yaml

replicaCount: 1

# env:
#   FILE_BROWSER: ""

# keeper:
#   image:
#     tag: jx3-kind-install

# webhooks:
#   image:
#     tag: jx3-kind-install
EOF
`

FILE_NGINX_VALUES=`cat << EOF
controller:
  hostPort:
    enabled: true
  service:
    type: ClusterIP
  replicaCount: 1
  config:
    # since the docker registry is being used via ingress
    # an alternative to making this global is to convigure the docker-registry ingress to use an annotation
    proxy-body-size: 1g
EOF
`


FILE_OWNERS=`cat << EOF
approvers:
- ${DEVELOPER_USER}
reviewers:
- ${DEVELOPER_USER}
EOF
`

FILE_REPO_JSON=`cat << 'EOF'
{
  "auto_init": false,
  "description": "",
  "gitignores": "",
  "issue_labels": "",
  "license": "",
  "name": "name",
  "private": true,
  "readme": ""
} 
EOF
`

FILE_SECRET_INFRA_HELMFILE=`cat << 'EOF'
filepath: ""
environments:
  default:
    values:
    - jx-values.yaml
namespace: secret-infra
repositories:
- name: external-secrets
  url: https://external-secrets.github.io/kubernetes-external-secrets
- name: banzaicloud-stable
  url: https://kubernetes-charts.banzaicloud.com
- name: jx3
  url: https://storage.googleapis.com/jenkinsxio/charts
releases:
- chart: external-secrets/kubernetes-external-secrets
  version: 6.0.0
  name: kubernetes-external-secrets
  values:
  - ../../versionStream/charts/external-secrets/kubernetes-external-secrets/values.yaml.gotmpl
  - jx-values.yaml
- chart: banzaicloud-stable/vault-operator
  version: 1.3.0
  name: vault-operator
  values:
  - jx-values.yaml
- chart: jx3/vault-instance
  version: 1.0.1
  name: vault-instance
  values:
  - jx-values.yaml
- chart: jx3/pusher-wave
  version: 0.4.12
  name: pusher-wave
  values:
  - jx-values.yaml
templates: {}
renderedvalues: {}
EOF
`

FILE_USER_JSON=`cat << 'EOF'
{
  "admin": true,
  "email": "developer@example.com",
  "full_name": "full_name",
  "login_name": "login_name",
  "must_change_password": false,
  "password": "password",
  "send_notify": false,
  "source_id": 0,
  "username": "username"
}
EOF
`

startDockerRegistryProxy() {
  id=`docker run -d --rm \
    -e REGISTRIES="${DOCKER_REGISTRY_PROXY_REGISTRIES}" \
    -e AUTH_REGISTRIES="${DOCKER_REGISTRY_PROXY_AUTH_REGISTRIES}" \
    -e ENABLE_MANIFEST_CACHE="true" \
    -v "${DOCKER_REGISTRY_PROXY_CACHE_FOLDER}/docker_mirror_cache":/docker_mirror_cache \
    -v "${DOCKER_REGISTRY_PROXY_CACHE_FOLDER}/docker_mirror_certs":/ca \
    -p "${DOCKER_REGISTRY_PROXY_PORT}:3128" \
    --name ${DOCKER_REGISTRY_PROXY_CONTAINER_NAME} \
    rpardini/docker-registry-proxy`
  info "docker-registry-proxy running with container id ${id}"
stopDockerRegistryProxy() {
  docker stop docker-registry-proxy
}
}



buildKindNodeImage() {
  tmp=`mktemp -d`
  pushd "${tmp}"
  echo "${FILE_KIND_NODE_IMAGE_DOCKERFILE}" > Dockerfile
  echo "${FILE_KIND_NODE_IMAGE_HTTP_PROXY_CONF}" > http-proxy.conf
  docker build -t kind-jx3-node:latest .
  popd
  rm -rf "${tmp}"
}

isPodReady() {
  ns="${1}"
  selector="${2}"

  kubectl wait --for="condition=ready" -n "${ns}" pod --selector="${selector}" --timeout="10s"
}

expectPodsReadyByLabel() {

  ns="${1}"
  selector="${2}"

  # using a single wait like the following can be flakey - ive seen cases where the pod is ready (verified by running the same command in a separate terminal while this one is still pending)
  # {my suspicion is that the wait command evaluates the selector once, then wathces that pod by name.  So if the pod is deleted and another is created, it will timeout with a failure}
#  kubectl -n "${ns}" wait --for=condition=ready pod --selector="${selector}" --timeout="${timeout}"
  
  # conceptually we want to wait for any pod that matches the selector, so doing it this way re-runs the selector each 'waitFor' loop
  waitFor "10 minute" "$ns : $selector to be ready" isPodReady "${ns}" "${selector}" || exit 1

}

# expectPodCount() {
#   ns=${1}
#   selector=${2}
#   timeout=${3:-"5 minute"}
#   count=${3:-"1"}

#   endtime=$(date -ud "$runtime" +%s)

#   while [[ $(date -u +%s) -le $endtime ]]
#   do
#     kubectl -n "${ns}" get pod --selector="${selector}" 

#     substep "Waiting for ${count} pods in $ns $selector"

#     sleep 5
#   done
  
# }

loadImage() {
  substep "Loading image $1"

  if `docker inspect --type=image "$1" 2>&1 >/dev/null`; then
    :
  else
    docker pull "$1"
  fi
  
  kind load docker-image --name=jx3 "$1"
}


TOKEN=""
giteaCreateUserAndToken() {
  username=$1
  password=$2

  request=`echo "${FILE_USER_JSON}" \
    | yq e '.email="'${username}@example.com'"' - \
    | yq e '.full_name="'${username}'"' - \
    | yq e '.login_name="'${username}'"' - \
    | yq e '.username="'${username}'"' - \
    | yq e '.password="'${password}'"' -`

  substep "creating ${username} user"
  response=`echo "${request}" | curl -s -X POST "${GIT_URL}/api/v1/admin/users" "${CURL_GIT_ADMIN_AUTH[@]}" "${CURL_TYPE_JSON[@]}" --data @-`
  # info $request
  # info $response

  substep "updating ${username} user"
  response=`echo "${request}" | curl -s -X PATCH "${GIT_URL}/api/v1/admin/users/${username}" "${CURL_GIT_ADMIN_AUTH[@]}" "${CURL_TYPE_JSON[@]}" --data @-`
  # info $response

  substep "creating ${username} token"
  curlBasicAuth "${username}" "${password}"
  response=`curl -s -X POST "${GIT_URL}/api/v1/users/${username}/tokens" "${CURL_AUTH[@]}" "${CURL_TYPE_JSON[@]}" --data '{"name":"jx3"}'` 
  # info $response
  token=`echo "${response}" | yq eval '.sha1' -`
  if [[ "$token" == "null" ]]; then
    info "Failed to create token for ${username}, json response: \n${response}"
    exit 1
  fi
  TOKEN="${token}"
}


kind_bin="${DIR}/kind"
installKind() {

  if [ -x "${kind_bin}" ] ; then
    # kind in current dir
    :
  else
    step "Installing kind"
    curl -L -s https://github.com/kubernetes-sigs/kind/releases/download/v0.9.0/kind-linux-amd64 > ${kind_bin}
    chmod +x ${kind_bin}
  fi
}
kind() {
  "${kind_bin}" "$@"
}


helm_bin=`which helm || true`
installHelm() {
  if [ -x "${helm_bin}" ] ; then
    # helm in path
    :
  else
    step "Installing helm"
    curl -s https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | "${helm_bin}"
    helm_bin=`which helm`
  fi
}
helm() {
  "${helm_bin}" "$@"
}


yq_bin="${DIR}/yq"
installYq() {
  if [ -x "${yq_bin}" ] ; then
    # yq in current dir
    :
  else
    step "Installing yq"
    curl -L -s https://github.com/mikefarah/yq/releases/download/v4.2.0/yq_linux_amd64 > "${yq_bin}"
    chmod +x "${yq_bin}"
  fi
}

yq() {
  "${yq_bin}" "$@"
}

help() {
  # TODO
  info "run 'jx3-kind.sh create' or 'jx3-kind.sh destroy'"
}

destroy() {

  if [[ -f log ]]; then
    rm log
  fi
  if [[ -d node-http ]]; then
    rm -rf ./node-http
  fi
  rm -f .*.token || true

  set -euo pipefail

  kind delete cluster --name=jx3
  docker network rm jx3

}

createKindCluster() {


  step "Creating kind cluster named jx3"

  if [[ "${DOCKER_REGISTRY_PROXY}" == "true" ]]; then
    substep "Build custom node image"
    buildKindNodeImage
  fi

  # create our own docker network so that we know the node's IP address ahead of time (easier than guessing the next avail IP on the kind network)
  networkId=`docker network create -d bridge --subnet "${SUBNET}" --gateway "${GATEWAY}" jx3`
  info "Node IP is ${IP}"


  IMAGE=""
  if [[ "${DOCKER_REGISTRY_PROXY}" == "true" ]]; then
    IMAGE="kind-jx3-node:latest"
  fi

  # https://kind.sigs.k8s.io/docs/user/local-registry/
  cat << EOF | env KIND_EXPERIMENTAL_DOCKER_NETWORK=jx3 kind create cluster --name jx3 --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.configs."*".tls]
    insecure_skip_verify = true
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker-registry-jx.${IP}.nip.io:80"]
    endpoint = ["http://docker-registry-jx.${IP}.nip.io:80"]
nodes:
- role: control-plane
  image: $IMAGE
EOF

  ## verify that the first node's IP address is what we have configured the registry mirror with
  internalIp=`kubectl get node -o jsonpath="{.items[0]..status.addresses[?(@.type == 'InternalIP')].address}"`
  if [[ "${IP}" != "${internalIp}" ]]; then
    info "First node's internalIp '${internalIp}' is not what was expected '${IP}'"
    exit 1
  fi

  # Document the local registry
  # https://github.com/kubernetes/enhancements/tree/master/keps/sig-cluster-lifecycle/generic/1755-communicating-a-local-registry

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "docker-registry-jx.${IP}.nip.io:80"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

}

configureHelm() {
  step "Configuring helm chart repositories"

  substep "ingress-nginx"
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  substep "gitea-charts"
  helm repo add gitea-charts https://dl.gitea.io/charts/ 
  substep "helm repo update"
  helm repo update 
}

installNginxIngress() {

  step "Installing nginx ingress"

  kubectl create namespace nginx 
  echo "${FILE_NGINX_VALUES}" | helm install nginx --namespace nginx --values - ingress-nginx/ingress-nginx 

  substep "Waiting for nginx to start"

  expectPodsReadyByLabel nginx app.kubernetes.io/name=ingress-nginx

}

installGitea() {
  step "Installing Gitea"

  kubectl create namespace gitea 

  echo "${FILE_GITEA_VALUES_YAML}" | helm install --namespace gitea -f - gitea gitea-charts/gitea 

  substep "Waiting for Gitea to start"

  expectPodsReadyByLabel gitea app.kubernetes.io/name=gitea


  # Verify that gitea is serving
  for i in {1..20}; do
    http_code=`curl -LI -o /dev/null -w '%{http_code}' -s "${GIT_URL}/api/v1/admin/users" "${CURL_GIT_ADMIN_AUTH[@]}"`
    if [[ "${http_code}" = "200" ]]; then
      break
    fi
    sleep 1
  done

  if [[ "${http_code}" != "200" ]]; then
    info "Gitea didn't startup"
    exit 1
  fi

  info "Gitea is up at ${GIT_URL}"
  info "Login with username: gitea_admin password: ${GITEA_ADMIN_PASSWORD}"
}

configureGiteaOrgAndUsers() {

  step "Creating ${DEVELOPER_USER} and ${BOT_USER} users"

  giteaCreateUserAndToken "${BOT_USER}" "${BOT_PASS}"
  botToken="${TOKEN}"
  echo "${botToken}" > ${DIR}/.bot.token
  info "botToken = /${botToken}/"

  giteaCreateUserAndToken "${DEVELOPER_USER}" "${DEVELOPER_PASS}"
  developerToken="${TOKEN}"
  echo "${developerToken}" > ${DIR}/.developer.token
  step "Creating ${ORG} organisation"

  curlTokenAuth "${developerToken}"
  json=`curl -s -X POST "${GIT_URL}/api/v1/orgs" "${CURL_AUTH[@]}" "${CURL_TYPE_JSON[@]}" --data '{"repo_admin_change_team_access": true, "username": "'${ORG}'", "visibility": "private"}'`
  info "$json"

  step "Add ${BOT_USER} an owner of ${ORG} organisation"

  substep "find owners team for ${ORG}"
  curlTokenAuth "${developerToken}"
  json=`curl -s "${GIT_URL}/api/v1/orgs/${ORG}/teams/search?q=owners" "${CURL_AUTH[@]}" "${CURL_TYPE_JSON[@]}"`
  id=`echo "${json}" | yq eval '.data[0].id' -`
  if [[ "${id}" == "null" ]]; then
    info "Unable to find owners team, json response :\n${json}"
    exit 1
  fi

  substep "add ${BOT_USER} as member of owners team (#${id}) for ${ORG}"
  curlTokenAuth "${developerToken}"
  response=`curl -s -X PUT "${GIT_URL}/api/v1/teams/${id}/members/${BOT_USER}" "${CURL_AUTH[@]}" "${CURL_TYPE_JSON[@]}"`

}

loadGitUserTokens() {
  botToken=`cat .bot.token`
  developerToken=`cat .developer.token`
}

createClusterRepo() {

  loadGitUserTokens

  step "Create jx3-cluster-repo"

  json=`echo "${FILE_REPO_JSON}" | yq e '.name="jx3-cluster-repo"' - `
  # echo $json
  curlTokenAuth "${developerToken}"
  echo "${json}" | curl -s -X POST "${GIT_URL}/api/v1/orgs/${ORG}/repos" "${CURL_AUTH[@]}" "${CURL_TYPE_JSON[@]}" --data @-

  substep "checkout from git"

  tmp=`mktemp -d`
  pushd "${tmp}"
  # git clone https://github.com/cameronbraid/jx3-kind-vault
  git clone https://github.com/jx3-gitops-repositories/jx3-kind-vault


  substep "change remote to point to gitea"
  pushd jx3-kind-vault
  git remote remove origin
  git remote add origin "${GIT_SCHEME}://${DEVELOPER_USER}:${developerToken}@${GIT_HOST}/${ORG}/jx3-cluster-repo"
  if [[ "$JX_GITOPS_UPGRADE" == "true" ]]; then
    substep "jx gitops upgrade"
    jx gitops upgrade
  fi


  substep "update OWNERS"
  echo "${FILE_OWNERS}" > OWNERS
  git add .
  git commit -a -m 'feat: jx gitops upgrade and add OWNERS file'


  substep "update .gitignore"
  echo ".history" >> .gitignore
  git commit -a -m 'chore: git ignore .history folder'


  substep "configure kpt-strategy.yaml"
  mkdir -p .jx/gitops
  echo "${FILE_KPT_STRATEGY_YAML}" > .jx/gitops/kpt-strategy.yaml
  git add .
  git commit -a -m 'feat: add kpt-strategy.yaml'

  substep "remove nginx helmfile"
  yq eval 'del( .helmfiles.[] | select(.path == "helmfiles/nginx/helmfile.yaml") )' -i ./helmfile.yaml
  rm -rf helmfiles/nginx

  substep "add secret-infra helmfile"
  mkdir helmfiles/secret-infra -p
  
  echo "${FILE_SECRET_INFRA_HELMFILE}" > helmfiles/secret-infra/helmfile.yaml

  yq eval '.helmfiles += {"path":"helmfiles/secret-infra/helmfile.yaml"}' -i ./helmfile.yaml
  yq eval '.spec.defaults.backendType = "vault"' -i .jx/secret/mapping/secret-mappings.yaml
  git add .
  git commit -a -m 'feat: configure vault'


  substep "configure ligthhouse"

  echo "${FILE_JX_LIGTHHOUSE_VALUES_YAML}" > helmfiles/jx/jx-ligthhouse-values.yaml
  yq eval '(.releases.[] | select(.name == "lighthouse")).values += "jx-ligthhouse-values.yaml"' -i helmfiles/jx/helmfile.yaml
  yq eval '(.releases.[] | select(.name == "lighthouse")).version = "'${LIGHTHOUSE_VERSION}'"' -i helmfiles/jx/helmfile.yaml
  yq eval '.version = "'${LIGHTHOUSE_VERSION}'"' -i versionStream/charts/jenkins-x/lighthouse/defaults.yaml

  # # newer lighthouse enforces that trigger is a pattern and that rerun_command MUST match it
  # yq eval '(.spec.presubmits.[] | select(.name == "verify")).trigger = "(?m)^\/(re)?test"' -i .lighthouse/jenkins-x/triggers.yaml

  git add .
  git commit -a -m 'feat: patch lighthouse config'



  substep "configure pipeline-catalog which has trigger.yaml files compatible with latest lighthouse"

  yq eval '(.spec.repositories.[] | select(.label == "JX3 Pipeline Catalog")).gitUrl = "https://github.com/cameronbraid/jx3-pipeline-catalog"' -i extensions/pipeline-catalog.yaml
  yq eval '(.spec.repositories.[] | select(.label == "JX3 Pipeline Catalog")).gitRef = "master"' -i extensions/pipeline-catalog.yaml



  substep "make sure there is a secrets array in spec.secrets"
  yq eval '.spec.secrets.[] |= {}' -i .jx/secret/mapping/secret-mappings.yaml

  substep "configure minio - secret schema"
  # https://github.com/jenkins-x/jx-secret#mappings
  mkdir charts/minio/minio -p
  echo "${FILE_MINIO_SECRET_SCHEMA_YAML}" > charts/minio/minio/secret-schema.yaml

  substep "configure minio - secret mapping"
  yq eval '.spec.secrets += {"name":"minio","mappings":[{"name":"accesskey","key":"secret/data/minio","property":"accesskey"},{"name":"secretkey","key":"secret/data/minio","property":"secretkey"}]}' -i .jx/secret/mapping/secret-mappings.yaml

  substep "configure minio - helmfile"
  # add minio helm repository
  yq eval '.repositories += {"name":"minio","url":"https://helm.min.io/"}' -i helmfiles/jx/helmfile.yaml
  # add minio release
  yq eval '.releases += {"chart":"minio/minio","version":"8.0.9","name":"minio","values":["jx-values.yaml", "minio-values.yaml.gotmpl"]}' -i helmfiles/jx/helmfile.yaml
  echo "${FILE_MINIO_VALUES_YAML_GOTMPL}" > helmfiles/jx/minio-values.yaml.gotmpl


  substep "configure docker-registry - helmfile"
  echo "${FILE_DOCKER_REGISTRY_VALUES_YAML_GOTMPL}" > helmfiles/jx/docker-registry-values.yaml.gotmpl
  yq eval '(.releases.[] | select(.name == "docker-registry")).values += "docker-registry-values.yaml.gotmpl"' -i helmfiles/jx/helmfile.yaml

  substep "configure docker-registry - secret mapping"
  yq eval '.spec.secrets += {"name":"docker-registry-secret","mappings":[{"name":"s3AccessKey","key":"secret/data/minio","property":"accesskey"},{"name":"s3SecretKey","key":"secret/data/minio","property":"secretkey"},{"name":"haSharedSecret","key":"secret/data/minio","property":"secretkey"}]}' -i .jx/secret/mapping/secret-mappings.yaml

  substep "configure bucketrepo - helmfile"
  yq eval '(.releases.[] | select(.name == "bucketrepo")).values += "bucketrepo-values.yaml"' -i helmfiles/jx/helmfile.yaml
  yq eval '(.releases.[] | select(.name == "jenkins-x/bucketrepo")).version = "0.1.53"' -i helmfiles/jx/helmfile.yaml
  echo "${FILE_BUCKETREPO_VALUES}" > helmfiles/jx/bucketrepo-values.yaml

  substep "configure bucketrepo - secret mapping"
  yq eval '.spec.secrets += {"name":"jenkins-x-bucketrepo-env","mappings":[{"name":"AWS_ACCESS_KEY","key":"secret/data/minio","property":"accesskey"},{"name":"AWS_SECRET_KEY","key":"secret/data/minio","property":"secretkey"}]}' -i .jx/secret/mapping/secret-mappings.yaml

  # substep "configure in-repo scheduler"
  # yq eval '.spec.owners |= {}' -i versionStream/schedulers/in-repo.yaml
  # yq eval '.spec.owners.skip_collaborators |= []' -i versionStream/schedulers/in-repo.yaml
  # yq eval '.spec.owners.skip_collaborators += "'${ORG}'"' -i versionStream/schedulers/in-repo.yaml

  substep "configure jx-build-controller"

  echo "${FILE_JX_BUILD_CONTROLLER_VALUES_YAML}" > helmfiles/jx/jx-build-controller-values.yaml
  yq eval '(.releases.[] | select(.name == "jx-build-controller")).values += "jx-build-controller-values.yaml"' -i helmfiles/jx/helmfile.yaml
  git add .
  git commit -a -m 'feat: patch jx-build-controller config'


  substep "configure jx-requirements"

  yq eval '.spec.cluster.clusterName = "kind"' -i ./jx-requirements.yml
  yq eval '.spec.cluster.registry = "docker-registry-jx.'${IP}'.nip.io:80"' -i ./jx-requirements.yml
  yq eval '.spec.cluster.devEnvApprovers[0] = "'${DEVELOPER_USER}'"' -i ./jx-requirements.yml
  yq eval '.spec.cluster.devEnvApprovers += "'${BOT_USER}'"' -i ./jx-requirements.yml
  yq eval '.spec.cluster.environmentGitOwner = "'${ORG}'"' -i ./jx-requirements.yml
  yq eval '.spec.cluster.gitKind = "gitea"' -i ./jx-requirements.yml
  yq eval '.spec.cluster.gitName = "gitea"' -i ./jx-requirements.yml
  yq eval '.spec.cluster.gitServer = "http://gitea.'${IP}'.nip.io"' -i ./jx-requirements.yml
  yq eval '.spec.cluster.provider = "kind"' -i ./jx-requirements.yml
  yq eval '.spec.environments[0].owner = "'${ORG}'"' -i ./jx-requirements.yml
  yq eval '.spec.environments[0].repository = "jx3-cluster-repo"' -i ./jx-requirements.yml
  yq eval '.spec.ingress.domain = "'${IP}'.nip.io"' -i ./jx-requirements.yml
  yq eval '.spec.secretStorage = "vault"' -i ./jx-requirements.yml
  yq eval '.spec.storage = []' -i ./jx-requirements.yml
  yq eval '.spec.storage += [{"name":"repository", "url":"s3://jx3/bucketrepo?endpoint=minio.jx.svc.cluster.local:9000&disableSSL=true&s3ForcePathStyle=true&region=ignored"}]' -i ./jx-requirements.yml
  yq eval '.spec.storage += [{"name":"logs", "url":"s3://jx3/logs?endpoint=minio.jx.svc.cluster.local:9000&disableSSL=true&s3ForcePathStyle=true&region=ignored"}]' -i ./jx-requirements.yml
  yq eval '.spec.storage += [{"name":"reports", "url":"s3://jx3/reports?endpoint=minio.jx.svc.cluster.local:9000&disableSSL=true&s3ForcePathStyle=true&region=ignored"}]' -i ./jx-requirements.yml

  git commit -a -m 'feat: configure jx-requirements'

  substep "push changes"

  git push --set-upstream origin master

  popd
  popd

  rm -rf "${tmp}"

}

installJx3GitOperator() {
  loadGitUserTokens

  step "Installing jx3-git-operator"
  # https://jenkins-x.io/v3/admin/guides/operator/#insecure-git-repositories
  #  --setup "git config --global http.sslverify false"
  jx admin operator --batch-mode --url="${GIT_URL}/${ORG}/jx3-cluster-repo" --username "${BOT_USER}" --token "${botToken}"

  kubectl config set-context --current --namespace=jx
}

waitForJxPodsToStart() {
  expectPodsReadyByLabel jx app=docker-registry
  expectPodsReadyByLabel jx app=bucketrepo-bucketrepo
  expectPodsReadyByLabel jx app=minio
} 

createNodeHttpDemoApp() {
  loadGitUserTokens

  step "Create a demo app using the node-http quickstart"

  jx project quickstart --batch-mode --git-kind gitea --git-username "${DEVELOPER_USER}" --git-token "${developerToken}" -f node-http --pack javascript --org "${ORG}"

  # needed until skip_collaborators is working above in in-repo scheduler
  substep "Setup ${DEVELOPER_USER} as a colaborator fo the project"
  # developer is already in owners, however the /approve plugin needs them to be a collaborator as well
  curlTokenAuth "${developerToken}"
  response=`curl -s -X PUT "${GIT_URL}/api/v1/repos/${ORG}/node-http/collaborators/${DEVELOPER_USER}" "${CURL_AUTH[@]}" "${CURL_TYPE_JSON[@]}" --data '{"permission": "admin"}'`
  if [[ "$response" != "" ]]; then
    info "Failed adding ${DEVELOPER_USER} as a collaborator on node-http\n${response}"
    exit 1
  fi

}


waitFor() {
  timeout="$1"; shift
  label="$1"; shift
  command="$1"; shift
  args="$@"

  endtime=$(date -ud "${timeout}" +%s)
  substep "Waiting up to ${timeout} for: ${label}"
  while [[ $(date -u +%s) -le ${endtime} ]]
  do
    ${command} ${args[@]} 2>&1 >/dev/null && RC=$? || RC=$?
    if [[ $RC -eq 0 ]]; then
      return 0
    fi
    sleep 5
  done
  info "Gave up waiting for: ${label}"
  exit 1
}

isJxApplication() {
  environment="$1"; shift
  name="$1"; shift
  version="$1"; shift

  count=`jx get applications -e "${environment}" "${name}" 2>/dev/null | tail -n +2 | tr -s ' ' | cut -d ' ' -f 2 | grep "${version}" | wc -l  || true`
  if [[ "${count}" == "1" ]]; then
    return 0
  fi
  return 1

}

APPLICATION_URL=""
getApplicationUrl() {
  environment=${1}
  name=${2}
  version=${3}

  table=`jx get applications -e "${environment}" "${name}" 2>/dev/null | (grep "${version}" || true)`
  # info "${table}"
  if [[ `echo "$table" | wc -l` == "1" ]]; then
    APPLICATION_URL=`echo "${table}" | tr -s ' ' | cut -d ' ' -f 4`
  else
    info "More than one application found"
    exit 1
  fi
}

getUrlResponseContains() {
  url=$1
  expectedText=$2
  curl -s "${url}" | grep "$expectedText" > /dev/null
}

assertNodeHttpDemoApp() {
  environment="$1"; shift
  name="$1"; shift
  version="$1"; shift
  expectedText="$1"; shift

  step "Verify ${name} is deployed and serving traffic"

  waitFor "10 minute" "${name} v${version} in ${environment}" isJxApplication "${environment}" "${name}" "${version}"

  getApplicationUrl "${environment}" "${name}" "$version"

  waitFor "5 minute" "${APPLICATION_URL} responds with ${expectedText}" getUrlResponseContains "${APPLICATION_URL}" "${expectedText}"

}

verifyNodeHttpDemoApp() {
  assertNodeHttpDemoApp "staging" "node-http" "1.0.1" "Jenkins <strong>X</strong>"
}

updateNodeHttpDemoApp() {
  
  project="node-http"
  branch="update-header-to-jenkins-3"
  message="feat: update header to Jenkins X3"

  step "Update "${project}" demo and create PR"
  
  loadGitUserTokens

  substep "Clone ${project}"

  tmp=`mktemp -d`
  pushd "${tmp}"

  git clone "${GIT_SCHEME}://${DEVELOPER_USER}:${developerToken}@${GIT_HOST}/${ORG}/${project}"

  pushd "${project}"

  git checkout -b "${branch}"
  sed -i index.html -e 's|Jenkins <strong>X</strong>|Jenkins <strong>X3</strong>|'
  git add index.html
  git commit -m "${message}"
  git push origin "${branch}"

  popd
  popd
  rm -rf "${tmp}"

  curlTokenAuth "${developerToken}"
  pr=`cat <<EOF
  {
    "base": "master",
    "body": "${message}",
    "head": "${branch}",
    "title": "${message}"
  }
EOF
`
  response=`echo "${pr}" | curl -s "${GIT_URL}/api/v1/repos/${ORG}/${project}/pulls" "${CURL_AUTH[@]}" "${CURL_TYPE_JSON[@]}" --data @-`
  number=`echo "${response}" | yq eval '.number' -`
  if [[ "$number" == "null" ]]; then
    info "Failed to create PR, response: ${response}"
    exit 1
  fi
  echo "PR response ${response}"

  info "PR created number ${number}"

  substep "Add /approved comment to the pr so that it will automaticlaly merge"

  request='{"body":"/approve"}'
  response=`echo "${request}" | curl -s "${GIT_URL}/api/v1/repos/${ORG}/${project}/issues/${number}/comments" "${CURL_AUTH[@]}" "${CURL_TYPE_JSON[@]}" --data @-`
  # info "${response}"
  # {"id":59,"html_url":"http://gitea.172.21.0.2.nip.io/coders/node-http/pulls/9#issuecomment-59","pull_request_url":"http://gitea.172.21.0.2.nip.io/coders/node-http/pulls/9","issue_url":"","user":{"id":3,"login":"developer","full_name":"developer","email":"developer@example.com","avatar_url":"http://gitea.172.21.0.2.nip.io/user/avatar/developer/-1","language":"en-US","is_admin":true,"last_login":"2021-01-05T09:16:36Z","created":"2021-01-04T15:10:30Z","username":"developer"},"original_author":"","original_author_id":0,"body":"/approve","created_at":"2021-01-05T10:17:13Z","updated_at":"2021-01-05T10:17:13Z"}
}

verifyUpdatedNodeHttpDemoApp() {
  assertNodeHttpDemoApp "staging" "node-http" "1.0.2" "Jenkins <strong>X3</strong>"
}

create() {
  installKind
  installYq
  installHelm
  createKindCluster
  configureHelm
  installNginxIngress
  installGitea
  configureGiteaOrgAndUsers
  createClusterRepo
  installJx3GitOperator
  waitForJxPodsToStart
}

testProjectGitops() {
  createNodeHttpDemoApp
  verifyNodeHttpDemoApp
  updateNodeHttpDemoApp
  verifyUpdatedNodeHttpDemoApp
}

ci() {
  create
  testProjectGitops
}

function misc() {
  expectPodsReadyByLabel nginx app.kubernetes.io/name=ingress-nginx
}

function ciLoop() {
  if [ -x ".ci-loop" ]; then
    rm .ci-loop
  fi
  i=0
  while true; do
    ((i = i+1))
    echo "`date` ci run $i" >> .ci-loop
    info "CI RUN ${i}"
    ci
  done
}

function_exists() {
  declare -f -F $1 > /dev/null
  return $?
}

if `function_exists "${COMMAND}"`; then
  shift
  "${COMMAND}" "$@"
  exit $?
else
  info "Unknown command : ${COMMAND}"
  exit 1
fi

}