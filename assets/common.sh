#!/bin/bash
set -e

if [ -f "$source/$namespace_overwrite" ]; then
  namespace=$(cat $source/$namespace_overwrite)
elif [ -n "$namespace_overwrite" ]; then
  namespace=$namespace
fi

generate_awscli_kubeconfig() {
  payload=$1
  source=$2
  # Optional. Use the AWS EKS authenticator
  assume_aws_role=$(jq -r '.source.assume_aws_role // ""' < $payload)
  aws_region=$(jq -r '.source.aws_region // ""' < $payload)
  aws_access_key_id=$(jq -r '.source.aws_access_key_id // ""' < $payload)
  aws_secret_access_key=$(jq -r '.source.aws_secret_access_key // ""' < $payload)
  if [ ! -z "$assume_aws_role" ]; then
    if [ -z "$aws_region" ]; then
      echo 'No aws region specified in the source configuration with parameter aws_region. Defaulting to eu-west-1.'
      aws_region="us-west-2"
    fi
    if [ ! -z "$aws_access_key_id" ]; then
      export AWS_ACCESS_KEY_ID=$aws_access_key_id
    fi
    if [ ! -z "$aws_secret_access_key" ]; then
      export AWS_SECRET_ACCESS_KEY=$aws_secret_access_key
    fi
    echo "Assuming aws role with arn $assume_aws_role"
    export temp_credentials=$(aws sts assume-role --role-arn $assume_aws_role --role-session-name concourse-helm-resource-session)
    export AWS_ACCESS_KEY_ID=$(echo ${temp_credentials} | jq -r '.Credentials.AccessKeyId') AWS_SESSION_TOKEN=$(echo ${temp_credentials} | jq -r '.Credentials.SessionToken') AWS_SECRET_ACCESS_KEY=$(echo ${temp_credentials} | jq -r ' .Credentials.SecretAccessKey') AWS_DEFAULT_REGION=$aws_region
  fi
  local aws_eks_cluster_name
  aws_eks_cluster_name="$(jq -r '.source.aws_eks_cluster_name // ""' < "$payload")"
  aws eks update-kubeconfig --name $aws_eks_cluster_name
}

setup_kubernetes() {
  payload=$1
  source=$2

  mkdir -p /root/.kube
  kubeconfig_path=$(jq -r '.params.kubeconfig_path // ""' < $payload)
  absolute_kubeconfig_path="${source}/${kubeconfig_path}"

  use_awscli_eks_auth=$(jq -r '.source.use_awscli_eks_auth // "false"' < $payload)

  if [ -f "$absolute_kubeconfig_path" ]; then
    cp "$absolute_kubeconfig_path" "/root/.kube/config"
  elif [ "$use_awscli_eks_auth" == true ]; then
    echo "using aws cli to generate kubeconfig"
    generate_awscli_kubeconfig $1 $2
  else
    # Setup kubectl
    cluster_url=$(jq -r '.source.cluster_url // ""' < $payload)
    if [ -z "$cluster_url" ]; then
      echo "invalid payload (missing cluster_url)"
      exit 1
    fi
    if [[ "$cluster_url" =~ https.* ]]; then
      insecure_cluster=$(jq -r '.source.insecure_cluster // "false"' < $payload)
      cluster_ca=$(jq -r '.source.cluster_ca // ""' < $payload)
      admin_key=$(jq -r '.source.admin_key // ""' < $payload)
      admin_cert=$(jq -r '.source.admin_cert // ""' < $payload)
      token=$(jq -r '.source.token // ""' < $payload)
      token_path=$(jq -r '.params.token_path // ""' < $payload)

      if [ "$insecure_cluster" == "true" ]; then
        kubectl config set-cluster default --server=$cluster_url --insecure-skip-tls-verify=true
      else
        ca_path="/root/.kube/ca.pem"
        echo "$cluster_ca" | base64 -d > $ca_path
        kubectl config set-cluster default --server=$cluster_url --certificate-authority=$ca_path
      fi

      if [ -f "$source/$token_path" ]; then
        kubectl config set-credentials admin --token=$(cat $source/$token_path)
      elif [ ! -z "$token" ]; then
        kubectl config set-credentials admin --token=$token
      else
        mkdir -p /root/.kube
        key_path="/root/.kube/key.pem"
        cert_path="/root/.kube/cert.pem"
        echo "$admin_key" | base64 -d > $key_path
        echo "$admin_cert" | base64 -d > $cert_path
        kubectl config set-credentials admin --client-certificate=$cert_path --client-key=$key_path
      fi

      kubectl config set-context default --cluster=default --user=admin
    else
      kubectl config set-cluster default --server=$cluster_url
      kubectl config set-context default --cluster=default
    fi

    kubectl config use-context default
  fi

  kubectl version
}

setup_helm() {
  # $1 is the name of the payload file
  # $2 is the name of the source directory


  history_max=$(jq -r '.source.helm_history_max // "0"' < $1)

  helm_bin="helm"

  $helm_bin version

  helm_setup_purge_all=$(jq -r '.source.helm_setup_purge_all // "false"' <$1)
  if [ "$helm_setup_purge_all" = "true" ]; then
    local release
    for release in $(helm ls -aq --namespace $namespace )
    do
      helm delete --purge "$release" --namespace $namespace
    done
  fi
}

wait_for_service_up() {
  SERVICE=$1
  TIMEOUT=$2
  if [ "$TIMEOUT" -le "0" ]; then
    echo "Service $SERVICE was not ready in time"
    exit 1
  fi
  RESULT=`kubectl get endpoints --namespace=$namespace $SERVICE -o jsonpath={.subsets[].addresses[].targetRef.name} 2> /dev/null || true`
  if [ -z "$RESULT" ]; then
    sleep 1
    wait_for_service_up $SERVICE $((--TIMEOUT))
  fi
}

setup_repos() {
  repos=$(jq -c '(try .source.repos[] catch [][])' < $1)
  plugins=$(jq -c '(try .source.plugins[] catch [][])' < $1)

  local IFS=$'\n'

  if [ $plugins ]
  then
    for pl in $plugins; do
      plurl=$(echo $pl | jq -cr '.url')
      plversion=$(echo $pl | jq -cr '.version // ""')
      if [ -n "$plversion" ]; then
        $helm_bin plugin install $plurl --version $plversion
      else
        if [ -d $2/$plurl ]; then
          $helm_bin plugin install $2/$plurl
        else
          $helm_bin plugin install $plurl
        fi
      fi
    done
  fi

  if [ $repos ]
  then
    for r in $repos; do
      name=$(echo $r | jq -r '.name')
      url=$(echo $r | jq -r '.url')
      username=$(echo $r | jq -r '.username // ""')
      password=$(echo $r | jq -r '.password // ""')

      echo Installing helm repository $name $url
      if [[ -n "$username" && -n "$password" ]]; then
        $helm_bin repo add $name $url --username $username --password $password
      else
        $helm_bin repo add $name $url
      fi
    done

    $helm_bin repo update
  fi

  $helm_bin repo add stable https://kubernetes-charts.storage.googleapis.com
  $helm_bin repo update
}

setup_resource() {
  tracing_enabled=$(jq -r '.source.tracing_enabled // "false"' < $1)
  if [ "$tracing_enabled" = "true" ]; then
    set -x
  fi

  echo "Initializing kubectl..."
  setup_kubernetes $1 $2
  echo "Initializing helm..."
  setup_helm $1 $2
  setup_repos $1 $2
}
