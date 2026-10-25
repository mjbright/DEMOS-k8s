#
# Assumptions: kubeadm-style stacked etcd, TLS on client port 2379, an
# "etcd" container with etcdctl installed, and kubectl access to pods/exec.
# No certificate or private key is copied out of a Pod.
#
# Examples (all commands below are diagnostic):
#   etcdctl                                  # One Pod: local endpoint status
#   etcdctl member list -w table
#   etcdctl endpoint status -w table
#   etcdctl endpoint health -w table
#   etcdctl -x endpoint health -w table      # See actual kubectl command
#
#   etcdctl snapshot save /var/lib/etcd/snapshot1.db
#   sudo ls -al /var/lib/etcd/snapshot1.db
#
#   etcdctl_all                              # Status of discovered endpoints
#   etcdctl_all endpoint status -w table
#   etcdctl_all endpoint health -w table
#   etcdctl_all --leader                     # One JSON leader observation
#   etcdctl_all -L                           # Repeat leader observation
#   etcdctl_all --watch --interval 5 endpoint status -w table
#   ETCDCTL_NODE=cp2 etcdctl endpoint status -w json
#   ETCDCTL_CONTEXT=production etcdctl_all member list -w table
#   etcdctl -- get '/example/key with spaces' # Exact argv is preserved
#
# Configuration (set in the shell, or prefix an individual function call):
#   KUBECTL_BIN                 kubectl (one executable/function, not a string
#                               containing a command and its arguments)
#   ETCDCTL_CONTEXT             unset: use kubectl's current context
#   ETCDCTL_NAMESPACE           kube-system
#   ETCDCTL_SELECTOR            component=etcd
#   ETCDCTL_CONTAINER           etcd
#   ETCDCTL_POD                 explicit exec Pod; must match the selector
#   ETCDCTL_NODE                Kubernetes nodeName for exec Pod selection
#   ETCDCTL_ENDPOINTS           explicit comma-separated endpoint URLs
#   ETCDCTL_CLIENT_PORT         2379
#   ETCDCTL_CACERT              /etc/kubernetes/pki/etcd/ca.crt
#   ETCDCTL_CERT                /etc/kubernetes/pki/etcd/healthcheck-client.crt
#   ETCDCTL_KEY                 /etc/kubernetes/pki/etcd/healthcheck-client.key
#   ETCDCTL_DIAL_TIMEOUT        3s
#   ETCDCTL_COMMAND_TIMEOUT     10s
#   ETCDCTL_REQUEST_TIMEOUT     15s (kubectl requests, not a universal exec limit)
#
# Local dependencies: Bash 4+ and kubectl; Python 3 only for --leader/-L.
# Kubernetes label, container, mount paths, and certificate policy may differ
# outside kubeadm. Configure these explicitly; TLS verification stays enabled.
#
# Semantics and safety:
# - etcdctl requires exactly one eligible Pod unless POD or NODE is specified.
# - etcdctl_all selects one exec Pod and supplies ALL discovered Pod endpoints
#   to ONE etcdctl invocation. It does not execute a command separately in each
#   Pod. Individual etcdctl subcommands decide how an endpoint list is used.
# - Discovery uses non-terminating Running Pods with IPs, including unready
#   Pods. This is a Kubernetes view, NOT the authoritative etcd member list.
# - For membership-derived endpoint checks, etcdctl supports, for example:
#     etcdctl endpoint --cluster status -w table
# - Pod discovery is refreshed on every polling iteration. Polling stops on
#   the first failure. Use Ctrl-C to stop; there are no background jobs.
# - Only poll read-only commands. Both wrappers pass through destructive
#   etcdctl commands too: they are not an authorization or safety boundary.
# - --debug/-x prints argv to stderr; arguments can contain sensitive values.
# - No TTY or stdin forwarding is requested. Interactive transactions and
#   stdin-fed commands need a purpose-built kubectl exec -i invocation.
# - Snapshot paths refer to the container filesystem, not your workstation.
# - Wrapper options are parsed only before the etcdctl command. Use -- to end
#   wrapper parsing, e.g. etcdctl -- --help for the underlying etcdctl help.
# - stdout is reserved for etcdctl output (or leader JSON). Polling/debug/error
#   messages go to stderr. Nonzero kubectl/etcdctl statuses are propagated.
# - No local ETCDCTL_* environment variable is automatically forwarded into
#   the Pod. The configuration above is translated into explicit arguments.
# - etcdctl v3.4+ defaults to API v3. Older binaries need separate adaptation;
#   this depends on the etcdctl version, not the Kubernetes minor version.

