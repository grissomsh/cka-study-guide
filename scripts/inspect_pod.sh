#!/bin/bash

#是否开启 debug
debug=false
#命名空间
namespace=""
#pod name
pod_name=""
#检查所有
all=false
#忽略只重启过的 Pod
ignore_restart_pod=false

#打印用法
print_usage() {
  echo "使用方法: $0 -p <pod_name> -n <namespace> -a  [-d] [-i] [-h]"
  echo ""
  echo "选项说明:"
  echo "  -n <namespace>      指定命名空间"
  echo "  -p <pod name>       检查指定的 pod，如果不指定 namespace 就是 default"
  echo "  -a                  检查所有 pod"
  echo "  -d                  开启调试模式"
  echo "  -i                  忽略重启过的目前运行正常的 Pod"
  echo "  -h                  打印帮助信息（当前显示）"
  echo ""
}

# 解析命令行参数
while getopts "ahdin:p:c:" opt; do
  case $opt in
  a)
    all=true
    ;;
  d)
    debug=true
    ;;
  i)
    ignore_restart_pod=true
    ;;
  h)
    print_usage
    exit 0
    ;;
  n)
    namespace=$OPTARG
    ;;
  p)
    pod_name=$OPTARG
    ;;
  \?)
    echo "无效的选项: -$OPTARG" >&2
    print_usage
    exit 1
    ;;
  :)
    echo "选项 -$OPTARG 需要一个参数" >&2
    print_usage
    exit 1
    ;;
  esac
done

function print_red() {
  echo -e "\x1b[1;31m$1\x1b[0m"
}

function print_green() {
  echo -e "\x1b[1;32m$1\x1b[0m"
}

function print_bold() {
  echo -e "\033[1;m$1\033[0m"
}

# 读取输入
read_input() {

  print_bold "输入任意键继续..."
  read user_input </dev/tty

}

# 检查是否开启调试模式
if $debug; then
  set -x
fi

#需要确保当前脚本可以调用 kubectl


#定义容器退出码
declare -A EXIT_CODES=(["0"]="Purposely stopped, Used by developers to indicate that the container was automatically stopped" \
  ["1"]="Application error, Container was stopped due to application error or incorrect reference in the image specification" \
  ["125"]="Container failed to run error, The docker run command did not execute successfully" \
  ["126"]="Command invoke error, A command specified in the image specification could not be invoked" \
  ["127"]="File or directory not found, File or directory specified in the image specification was not found" \
  ["128"]="Invalid argument used on exit, Exit was triggered with an invalid exit code (valid codes are integers between 0-255)" \
  ["134"]="Abnormal termination (SIGABRT), The container aborted itself using the abort() function" \
  ["137"]="Immediate termination (SIGKILL), Container was immediately terminated by the operating system via SIGKILL signal" \
  ["139"]="Segmentation fault (SIGSEGV), Container attempted to access memory that was not assigned to it and was terminated" \
  ["143"]="Graceful termination (SIGTERM), Container received warning that it was about to be terminated, then terminated" \
  ["255"]="Exit Status Out Of Range, Container exited, returning an exit code outside the acceptable range, meaning the cause of the error is not known")

# 检查 pod 的状态
check_abnormal_pod() {

  local pod_name=$1
  local namespace=$2

  print_bold "---------Check Pod Events---------"
  # 检查事件
  local events=$(kubectl get events --field-selector involvedObject.name=$pod_name -n $namespace --sort-by='{.metadata.creationTimestamp}')

  if [[ -n $events ]]; then
    print_bold "Pod ${pod_name} 有需要关注的事件："
    print_red "$events"
  else
    print_bold "Pod ${pod_name} : 未找到重要事件，有可能事件已被覆盖！"
  fi

  print_bold "---------Begin to inspect all container status---------"

  # Pod 状态
  local container_statuses=$(kubectl get pods $pod_name -n $namespace -o json | jq -r '.status.containerStatuses')

  if [[ "$container_statuses" == "null" ]]; then

    print_bold "Pod 未调度，所以容器还未创建！"
    print_bold "---------Inspect all container status finished---------"
    return 0

  fi

  #检查所有 container
  echo "${container_statuses}" | jq -c '.[]' | while IFS= read -r container_status; do

    if [[ -n "$container_status" ]]; then

      local container_name=$(echo "$container_status" | jq -r '.name')
      print_bold "---------Inspect container: $container_name ---------"

      local current_state=$(echo "$container_status" | jq -r '.state')
      local restart_count=$(echo "$container_status" | jq -r '.restartCount')
      local last_state=$(echo "$container_status" | jq -r '.lastState')
      local ready=$(echo "$container_status" | jq -r '.ready')
      local reason=$(echo "$container_status" | jq -r '.lastState.terminated.reason')
      local exit_code=$(echo "$container_status" | jq -r '.lastState.terminated.exitCode')

      if [[ "$(echo "$current_state" | jq -e '.running' 2>/dev/null)" != "null" ]]; then
        print_green "1. Container 状态（state）：$current_state"
      else
        print_red "1. Container 状态（state）：$current_state"
      fi

      if [[ "$ready" == false ]]; then
        print_red "2. Container Ready 状态（ready）：$ready"
      else
        print_green "2. Container Ready 状态（ready）：$ready"
      fi
      echo "3. Container 重启次数（restartCount）：$restart_count"
      echo "4. Container 前一次状态（lastState）：$last_state"
      echo "4.1 Container 退出原因（reason）：$reason"
      echo "4.2 Container 退出码（exit code）：$exit_code"

      if [[ $exit_code =~ ^[0-9]+$ ]]; then
        echo "4.3 Pod 退出码释义： ${EXIT_CODES[$exit_code]}"
      fi
    else
      print_red "未找到 Container 状态信息。"
    fi

    if [ "$ready" == false ]; then
      print_bold "---------Print log---------"
      #打印当前日志
      print_bold "容器:$container_name - 当前启动日志："
      kubectl logs $pod_name -c $container_name -n $namespace --tail=15

      #打印前一次的日志
      print_bold "容器:$container_name - 前一次启动日志："
      kubectl logs $pod_name -p -c $container_name -n $namespace --tail=15
    elif [ "$restart_count" ] >0 && [ "$ignore_restart_pod" == false ]; then
      print_bold "---------Print log---------"

      #打印前一次的日志
      print_bold "容器:$container_name - 前一次启动日志："
      kubectl logs $pod_name -p -c $container_name -n $namespace --tail=15
    fi

    print_bold "---------Inspect finished---------"
  done
  print_bold "---------Inspect all container status finished---------"
}

#根据 label 来检查 pods
check_pods_by_label() {
  local label=$1
  local namespace=$2

  # 获取 Pod
  local pods=$(kubectl get pods -n $namespace -l $label --no-headers)

  # 检查 Pod 是否存在
  if [ -z "$pods" ]; then
    print_red "命名空间[${namespace}]不存在满足 label selector-${label} 的 Pod！"
    return 1
  fi

  check_pods "$pods" "$namespace"
}

#根据 namespace 来检查 pods
check_pods_by_namespace() {

  local namespace=$1

  # 获取 Pod
  local pods=$(kubectl get pods -n $namespace --no-headers)

  # 检查 Pod 是否存在
  if [ -z "$pods" ]; then
    print_red "命名空间[${namespace}]未找到任何 Pod，有可能是命名空间名称不准确或者该命名空间没有创建任何 Pod！"
    return 1
  fi

  check_pods "$pods" "$namespace"
}

#检查单个 Pod
check_single_pod() {
  local pod_name=$1
  local namespace=$2

  # 获取 Pod
  local pods=$(kubectl get pods $pod_name -n $namespace --no-headers)

  # 检查 Pod 是否存在
  if [ -z "$pods" ]; then
    print_red "命名空间[${namespace}]未找到 pod [$pod_name]!"
    return 1
  fi

  check_pods "$pods" "$namespace"

}

#查找所有的 pods
check_pods_by_all_namespace() {

  #获取所有 namespace
  local namespace_names=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}')

  IFS=" "
  for namespace_name in $namespace_names; do
    print_bold "--------------- Check namespace: $namespace_name---------------"
    check_pods_by_namespace "$namespace_name"
    print_bold "--------------- Check namespace: $namespace_name end---------------"
    echo ""
  done
}

# 检查 Pods
check_pods() {

  local pods=$1
  local namespace=$2
  local isNormal=true
  local msg=""

  while IFS=' ' read -r pod_name pod_ready pod_status pod_restart pod_up_time; do
    isNormal=true
    msg=""

    # 如果 Pod 处于 Completed 状态，则跳过
    if [[ "$pod_status" == "Completed" ]]; then
      break
    fi

    if [[ ! $(echo "$pod_ready" | cut -d'/' -f 1) == $(echo "$pod_ready" | cut -d'/' -f 2) ]]; then
      msg+="Pod 中的容器还未就绪：${pod_ready}\n"
      isNormal=false
    fi

    if [[ ! "$pod_status" == "Running" ]]; then
      msg+="Pod 运行状态不正常：${pod_status}\n"
      isNormal=false
    fi

    if [[ "$pod_restart" != "0" ]]; then
      msg+="Pod 发生了多次重启：${pod_restart}\n"
      if [[ ! $ignore_restart_pod == true ]]; then
        isNormal=false
      fi
    fi

    if [[ $isNormal == false ]]; then
      print_bold "------------Check Pod - ${pod_name}------------"
      # 去掉最后两个字符
      print_red "${msg%??}"
      check_abnormal_pod "$pod_name" "$namespace"
      print_bold "------------Check Pod - ${pod_name} end------------"
      read_input
    else
      print_green "$pod_name 运行正常。"
    fi

  done <<<"$pods"
}


# 执行（如果指定了 pod name 以及 namespace
if [[ ! -z $pod_name ]]; then
  if [[ -z $namespace ]]; then
    namespace="default"
  fi
  check_single_pod "$pod_name" "$namespace"
else
  if [[ ! -z $namespace ]]; then
    print_bold "---------------Check namespace: $namespace---------------"
    check_pods_by_namespace $namespace
    print_bold "---------------Check namespace: $namespace end---------------"
  elif [[ $all == true ]]; then
    check_pods_by_all_namespace
  fi
fi