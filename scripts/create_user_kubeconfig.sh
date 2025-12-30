#!/usr/bin/env bash

# Based on https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/#normal-user
#
# Creates a new user/kubeconfig - does not create/bind any roles to user
#
# Example usage:
#   $0 user1 [<op-file>]
#   $0 user2 [<op-file>]
#

TMP_DIR=~/tmp/kubeconfig.user$$
mkdir -p $TMP_DIR/
cd       $TMP_DIR/

which jq >/dev/null 2>&1 || sudo apt-get install -y jq

## -- Func: ------------------------------------------------------------------------------

die() { echo "$0: die - $*" >&2; exit 1; }

ADDUSER() {
    NEWUSER=$1; shift

    sudo adduser -gecos "User $NEWUSER" $NEWUSER --disabled-password
}

DESTROY() {
   for USER_NAME in $*; do
       kubectl get CertificateSigningRequest/${USER_NAME}-csr 2> /dev/null | grep -q csr &&
         kubectl delete CertificateSigningRequest/${USER_NAME}-csr
   done
}

GET_CONTEXT_INFO() {
    local CURRENT_CONTEXT=$( kubectl config current-context )
    local CLUSTER=$( kubectl config view -o jsonpath="{.contexts[?(@.name == \"$CURRENT_CONTEXT\")].context.cluster}" )

    CLUSTER_ADDR=$( kubectl config view -o jsonpath="{.clusters[?(@.name == \"$CLUSTER\")].cluster.server}" )
    echo "CURRENT_CONTEXT=$CURRENT_CONTEXT     CLUSTER=$CLUSTER        CLUSTER_ADDR=$CLUSTER_ADDR"
}

CREATE_KUBECONFIG() {
    USER_NAME=$1; shift
    GROUP=$1;     shift

    openssl genrsa -out ${USER_NAME}.key 2048 || die "Failed genrsa"

    local SUBJECT="/CN=${USER_NAME}"
    [ ! -z "$GROUP" ] && SUBJECT="/CN=${USER_NAME}/O=${GROUP}"

    openssl req -new -key ${USER_NAME}.key -out ${USER_NAME}.csr -subj $SUBJECT ||
        die "Failed req -new -key"

    CA_OPTS="-CAcreateserial -CA /etc/kubernetes/pki/ca.crt -CAkey /etc/kubernetes/pki/ca.key"

    # Need sudo to read ca.key file:
    VALIDITY="-days 30"
    VALIDITY=""
    sudo openssl x509 $CA_OPTS -req -in ${USER_NAME}.csr -out ${USER_NAME}.crt $VALIDITY

    WRITE_KUBECONFIG $USER_NAME
}

CREATE_KUBECONFIG_USING_CSR() {
    USER_NAME=$1; shift
    GROUP=$1;     shift

    openssl genrsa -out ${USER_NAME}.key 2048 || die "Failed genrsa"

    local SUBJECT="/CN=${USER_NAME}"
    [ ! -z "$GROUP" ] && SUBJECT="/CN=${USER_NAME}/O=${GROUP}"

    openssl req -new -key ${USER_NAME}.key -out ${USER_NAME}.csr -subj $SUBJECT ||
        die "Failed req -new -key"
    #openssl req -in ${USER_NAME}.csr -noout -text ||
    #    die "Failed req in"

    CSR=$( cat ${USER_NAME}.csr | base64 | tr -d '\n' )

    cat << EOF > signing-request.yaml 
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${USER_NAME}-csr
spec:
  #signerName: "labs.com/lab-student"
  signerName: kubernetes.io/kube-apiserver-client
  groups:
  - system:authenticated
  request: $CSR
  usages:
  - client auth
EOF

    kubectl create -f signing-request.yaml ||
        die "Failed create signing-request"
    kubectl certificate approve ${USER_NAME}-csr ||
        die "Failed certificate approve"
    kubectl get csr

    USER_CERT=${USER_NAME}.crt
    kubectl get csr ${USER_NAME}-csr -o jsonpath='{.status.certificate}' | base64 -d > $USER_CERT
    [ ! -s "${USER_CERT}" ] &&
        die "Failed to get user certificate to $USER_CERT"

    WRITE_KUBECONFIG $USER_NAME
}


WRITE_KUBECONFIG() {
    kubectl get cm  kube-root-ca.crt -o json | jq -r '.data."ca.crt"' > ca.crt ||
        die "Failed to get ca.crt"

    CA_CERT=$(        cat           ca.crt | base64 -w0)
    CLIENT_CA_CERT=$( cat ${USER_NAME}.crt | base64 -w0)
    CLIENT_KEY_DATA=$(cat ${USER_NAME}.key | base64 -w0)

    cat <<EOF > kubeconfig.${USER_NAME}
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: $CA_CERT
    server: ${CLUSTER_ADDR}
  name: k8s
contexts:
- context:
    cluster: k8s
    user: ${USER_NAME}
  name: k8s
current-context: k8s
kind: Config
preferences: {}
users:
- name: ${USER_NAME}
  user:
    client-certificate-data: $CLIENT_CA_CERT
    client-key-data: $CLIENT_KEY_DATA
EOF

    # echo; echo "---- Temp files:"
    # ls -al $TMP_DIR/
    echo; echo "---- User Kubeconfig file:"
    if [ $ADDUSER -ne 0 ]; then
        sudo mkdir -p /home/$NEW_USER/.kube
        sudo cp -a $PWD/kubeconfig.${USER_NAME} $OP_FILE
        sudo chown -R ${NEW_USER}:${NEW_USER} /home/$NEW_USER/.kube
        sudo ls -al $OP_FILE
    else
        cp -a $PWD/kubeconfig.${USER_NAME} $OP_FILE
        ls -al $OP_FILE
    fi
}

## -- Args: ------------------------------------------------------------------------------

USAGE=$( cat <<'EOF'

Usage:

    $0 [-u] [-g <group>] <user> [<opfile>]
        -u:         Create corresponding linux user account
        -g <group>: Provide group name (X.509 OU: Organization Unit)
        <opfile>:   Specify path to kubeconfig file to be generated

EOF
)

#echo "$USAGE"
#exit

[ -z "$1" ] && die "Missing arguments - $USAGE"

GROUP=""
OP_FILE=""
ADDUSER=0

[   "$1" = "-u" ] && { shift; ADDUSER=1;       }
[   "$1" = "-g" ] && { shift; GROUP=$1; shift; }

[ -z "$1" ] && die "Missing user argument - $USAGE"
NEW_USER=$1; shift


if [ $ADDUSER -ne 0 ]; then
    OP_FILE=/home/$NEW_USER/.kube/config
else
    [ !     -z "$1" ] && OP_FILE=$1
    [ -z "$OP_FILE" ] && OP_FILE=~/.kube/config.${NEW_USER}
fi

#echo "USER=$NEW_USER     GROUP=$GROUP    OP_FILE=$OP_FILE"
#exit

## -- Main: ------------------------------------------------------------------------------

[ $ADDUSER -ne 0 ] && ADDUSER $NEW_USER
DESTROY $NEW_USER

GET_CONTEXT_INFO
[ -z "$CLUSTER_ADDR" ] && die "Failed to set CLUSTER_ADDR"

# CREATE_KUBECONFIG_USING_CSR $NEW_USER $GROUP
CREATE_KUBECONFIG $NEW_USER $GROUP

