#!/bin/bash

. ../demos.rc

REPLICAS=10
REPLICAS=8

#APP_NAME=ckad-demo
#APP_CONTAINER=ckad-demo
#IMAGE_BASE=mjbright/ckad-demo
#IMAGE_TAG_PREFIX=""
APP_NAME=web
APP_CONTAINER=k8s-demo
IMAGE_BASE=mjbright/k8s-demo
IMAGE_TAG_PREFIX="alpine"
DEPLOY=deploy/$APP_NAME
SVC=svc/$APP_NAME

KUBECTL="kubectl -n demo"
kubectl get ns demo || RUN kubectl create ns demo
RUN kubectl rollout restart -n kube-system deployment coredns

TMP=~/tmp/demos
mkdir -p $TMP

# NOTE: $KUBECTL create deploy $APP_NAME --image ${IMAGE_BASE}:${IMAGE_TAG_PREFIX}1 --dry-run=client -o yaml | $KUBECTL create -f - --record=true
# Will only record:
#     REVISION  CHANGE-CAUSE
#     1         $KUBECTL create --filename=- --record=true
# in rollout history
#
# SOLUTION: manually insert the change-cause annotation:
#    $KUBECTL create deploy $APP_NAME --image mjbright/k8s-demo:2 --dry-run=client -o yaml | sed 's/^  labels:/\ \ annotations:\n\ \ \ \ kubernetes.io\/change-cause: WHY-NOT\n\ \ labels:/' > t.yaml


## Functions: ---------------------------------------------------------

PRESS() {
    #BANNER "$*"
    [ $PROMPTS -eq 0 ] && return

    echo "Press <return>"
    read _DUMMY
    [ "$_DUMMY" = "q" ] && exit 0
    [ "$_DUMMY" = "Q" ] && exit 0
}

CLEANUP() {
   $KUBECTL delete $DEPLOY
   $KUBECTL delete $SVC
}

BLUE_GREEN() {
   # CLEANUP:
   $KUBECTL get svc $APP_NAME 2>/dev/null | grep -q $APP_NAME &&
       RUN $KUBECTL delete svc $APP_NAME
   $KUBECTL get deploy ${APP_NAME}-blue 2>/dev/null | grep -q ${APP_NAME}-blue &&
       RUN $KUBECTL delete deploy ${APP_NAME}-blue
   $KUBECTL get deploy ${APP_NAME}-green 2>/dev/null | grep -q ${APP_NAME}-green &&
       RUN $KUBECTL delete deploy ${APP_NAME}-green

   RUN_PRESS $KUBECTL create deploy ${APP_NAME}-blue --image ${IMAGE_BASE}:${IMAGE_TAG_PREFIX}1
   RUN_PRESS $KUBECTL create deploy ${APP_NAME}-green --image ${IMAGE_BASE}:${IMAGE_TAG_PREFIX}2
   RUN $KUBECTL scale deploy ${APP_NAME}-blue --replicas 3
   RUN $KUBECTL scale deploy ${APP_NAME}-green --replicas 3

   # Replace 1st ocurrence of -blue (part of Service label, not the selector):
   $KUBECTL expose deploy ${APP_NAME}-blue --port 80 --type ClusterIP --name ${APP_NAME} --dry-run=client -o yaml |
       sed '1,/-blue/s/-blue//' > $TMP/service-${APP_NAME}.yaml

   RUN_PRESS cat $TMP/service-${APP_NAME}.yaml

   RUN_PRESS $KUBECTL create -f $TMP/service-${APP_NAME}.yaml 
   SVC_IP=$($KUBECTL get svc ${APP_NAME} -o custom-columns=CIP:.spec.clusterIP --no-headers)
   RUN_PRESS $KUBECTL describe svc ${APP_NAME}
   RUN_PRESS curl -sL $SVC_IP

   # Replace selector:
   sed 's/-blue/-green/' < $TMP/service-${APP_NAME}.yaml > $TMP/service-green.yaml 
   #cp -a service-blue.yaml service-green.yaml 

   RUN_PRESS cat $TMP/service-green.yaml 
   RUN_PRESS $KUBECTL apply -f $TMP/service-green.yaml 

   RUN_PRESS $KUBECTL describe svc ${APP_NAME}
   RUN_PRESS curl -sL $SVC_IP
}

## Args: --------------------------------------------------------------

STRATEGY=ROLLING

while [ ! -z "$1" ]; do
    case $1 in
        -rol*) STRATEGY=ROLLING;;
        -rec*) STRATEGY=RECREATE;;
        -bg*)  STRATEGY=BLUEGREEN;;
        *) die "Unknown option '$1'";;
    esac
    shift
done

## Main: --------------------------------------------------------------

CLEANUP 2>/dev/null

echo "
Start k1s.py in namespace 'demo'
    ./k1s.py -n demo
"

case $STRATEGY in
    ROLLING)
        #RUN_PRESS $KUBECTL create deploy $APP_NAME --image ${IMAGE_BASE}:${IMAGE_TAG_PREFIX}1 --record
        #CMD="$KUBECTL create deploy $APP_NAME --image ${IMAGE_BASE}:${IMAGE_TAG_PREFIX}1"
        #CMD="$KUBECTL create -f deploy-web.yaml"
        RUN_PRESS $KUBECTL create -f deploy-web.yaml
        #NORUN_PRESS "---- $CMD"
        #$CMD --dry-run=client -o yaml |
            #sed 's/^  labels:/\ \ annotations:\n\ \ \ \ kubernetes.io\/change-cause: CHANGE_CAUSE\n\ \ labels:/' |
            #sed "s?CHANGE_CAUSE?$CMD?" |
       
        #set -x
        IMAGE="${IMAGE_BASE}:${IMAGE_TAG_PREFIX}1"
        IMAGE1=$IMAGE
        #echo "-- $KUBECTL annotate deploy web kubernetes.io/change-cause="Created initial deployment using image $IMAGE""
        YELLOW "-- $KUBECTL annotate deploy web kubernetes.io/change-cause="Created initial deployment using image $IMAGE""; echo
        $KUBECTL annotate deploy web kubernetes.io/change-cause="Created initial deployment using image $IMAGE"
        #set +x
	      #tee $TMP/ROLLING_deploy_${APP_NAME}.yaml | $KUBECTL create -f -
        ;;
    RECREATE)
        # RECREATE:
        YAML1=$TMP/deploy_${APP_NAME}.yaml
        YAML2=$TMP/deploy_${APP_NAME}_recreate.yaml
        echo
        echo "Creating yaml file for blue and green deployments:"
        $KUBECTL create deploy ${APP_NAME} --image ${IMAGE_BASE}:${IMAGE_TAG_PREFIX}1 --dry-run=client -o yaml > $YAML1
        ls -al $YAML1
        sed -e 's/strategy: {}/strategy:\n    type: Recreate/' < $YAML1 > $YAML2
        ls -al $YAML2
        echo
        echo "---- diff $YAML1 $YAML2"
        diff $YAML1 $YAML2
        RUN_PRESS $KUBECTL create -f $YAML2
        # exit $?
        ;;
    BLUEGREEN)
        BLUE_GREEN;
        PRESS "Cleanup"
        $KUBECTL delete svc ${APP_NAME}
        $KUBECTL delete deploy ${APP_NAME}-blue
        $KUBECTL delete deploy ${APP_NAME}-green
        exit $?;;
esac

RUN_PRESS $KUBECTL expose $DEPLOY  --port 80
$KUBECTL get all | grep $APP_NAME

RUN_PRESS $KUBECTL scale $DEPLOY --replicas=$REPLICAS

echo
echo "NOTE: remember pause/resume during rollout"
#RUN_PRESS $KUBECTL set image $DEPLOY ${APP_CONTAINER}=${IMAGE_BASE}:${IMAGE_TAG_PREFIX}2 --record
IMAGE=${IMAGE_BASE}:${IMAGE_TAG_PREFIX}2
RUN_PRESS $KUBECTL set image $DEPLOY ${APP_CONTAINER}=${IMAGE}
YELLOW "-- $KUBECTL annotate deploy web kubernetes.io/change-cause="Upgraded to image $IMAGE""; echo
$KUBECTL annotate deploy web kubernetes.io/change-cause="Upgraded to image $IMAGE"

RUN_PRESS $KUBECTL rollout pause  $DEPLOY
RUN_PRESS $KUBECTL rollout resume $DEPLOY
RUN $KUBECTL rollout status ${DEPLOY}
RUN_PRESS $KUBECTL rollout history ${DEPLOY}

#RUN_PRESS $KUBECTL set image ${DEPLOY} ${APP_CONTAINER}=${IMAGE_BASE}:${IMAGE_TAG_PREFIX}3 --record
IMAGE=${IMAGE_BASE}:${IMAGE_TAG_PREFIX}3
RUN_PRESS $KUBECTL set image ${DEPLOY} ${APP_CONTAINER}=${IMAGE}
YELLOW "-- $KUBECTL annotate deploy web kubernetes.io/change-cause="Upgraded to image $IMAGE""; echo
$KUBECTL annotate deploy web kubernetes.io/change-cause="Upgraded to image $IMAGE"

RUN $KUBECTL rollout status ${DEPLOY}
RUN_PRESS $KUBECTL rollout history ${DEPLOY}
#RUN_PRESS $KUBECTL rollout undo ${DEPLOY}
RUN_PRESS $KUBECTL rollout undo ${DEPLOY} --to-revision 1
YELLOW "-- $KUBECTL annotate deploy web kubernetes.io/change-cause="Rolled back to initial revision using image $IMAGE1""; echo
$KUBECTL annotate deploy web kubernetes.io/change-cause="Rolled back to initial revision using image $IMAGE1"
RUN_PRESS $KUBECTL rollout history ${DEPLOY}

exit 0


