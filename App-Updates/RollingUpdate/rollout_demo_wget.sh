#!/bin/sh

#NAME=ckad-demo
NAME=web
[ ! -z "$1" ] && NAME=$1

KUBECTL="kubectl -n demo"

kubectl get ns demo || kubectl create ns demo

GET_SVC_IP() {
    IP=$($KUBECTL get svc $NAME --no-headers | awk '{ print $3; }')
}

GET_SVC_IP

CURL_OPTS="--connect-timeout 2 --max-time 4"
WGET_OPTS="-qO - --timeout 4 --tries 1"

GET_CMD="curl $CURL_OPTS"
GET_CMD="wget $WGET_OPTS"

#IMAGE_NAME=alpine
IMAGE_NAME=busybox
#IMAGE_NAME=ubuntu

LOOP_CONNECT_FROM_LOCAL_NODE() {
    while true; do
        if [ -z "$IP" ]; then
            GET_SVC_IP
        else
            curl $CURL_OPTS ${IP}:80/1;
            [ $? -ne 0 ] && GET_SVC_IP
        fi
        sleep 1;
    done
}

FROM_POD() {
    set -x

    $KUBECTL describe pod testpod 2>&1 | grep Image: | grep " ${IMAGE_NAME}$"
    if [ $? -eq 0 ]; then
        $KUBECTL exec -it testpod -- sh -c "while true; do $GET_CMD web/1; sleep 1; done"
        $KUBECTL label testpod hide=k1spy
    else
        #$KUBECTL run testpod --rm -it --image ${IMAGE_NAME} -- sh -c "while true; do $GET_CMD web/1; sleep 1; done"
        #$KUBECTL run testpod --dry-run=client -o yaml --rm -it --image ${IMAGE_NAME} -- sh -c "while true; do $GET_CMD web/1; sleep 1; done" |
        $KUBECTL run testpod --dry-run=client -o yaml --image ${IMAGE_NAME} -- sh -c "while true; do $GET_CMD web/1; sleep 1; done" |
            sed -e 's/run: testpod/hide: k1spy/' | $KUBECTL apply -f -
        while true; do $KUBECTL logs testpod -f; sleep 2; done
    fi
}

ON_CLUSTER_NODE_P() {
    echo "Checking if running on Cluster node:"

    echo; echo "---- Looking to see if a kubelet is running on this node:"
    ps -fade | grep -v grep | grep 'kubelet ' || {
        echo; echo "---- Not a cluster node: No kubelet running locally"
        return 1
    }

    echo; echo "---- Trying to obtain current context"
    CONTEXT=$( $KUBECTL config get-contexts -o name --context current )
    [ -z "$CONTEXT" ] && {
        echo; echo "---- Not a cluster node: failed to get cluster context"
        return 1
    }

    echo; echo "---- Trying to obtain apiserver ip address of current context"
    IP=$( $KUBECTL config view --context $CONTEXT  | grep -m 1 server: | sed -e 's?.*https://??' -e 's/:.*//' )
    HOST_IP=$( hostname -i )

    [ -z "$IP" ] && {
        echo; echo "---- Not a cluster node: failed to get apiserver ip address"
        return 1
    }

    [ -z "$HOST_IP" ] && {
        echo; echo "---- Not a cluster node: failed to get hostname ip address"
        return 1
    }

    echo; echo "---- Comparing apiserver ip address with address of this node"
    [ "$IP" != "$HOST_IP" ] && {
        echo; echo "---- Not a cluster node: apiserver ip ($IP) != host ip address ($HOST_IP)"
        return 1
    }

    echo; echo "---- Looks like we're running on the active control plane node"
    return 0
}

if ON_CLUSTER_NODE_P ; then
    echo; echo "Looks like we're running on the main control-plane node - using curl directly"
    LOOP_CONNECT_FROM_LOCAL_NODE
else
    echo; echo "Looks like we're running on a remote node - using wget from a Pod"
    FROM_POD
fi


