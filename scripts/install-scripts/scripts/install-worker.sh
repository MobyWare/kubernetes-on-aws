#!/bin/bash
set -e

# List of etcd servers (http://ip:port), comma separated
export ETCD_ENDPOINTS=

# The endpoint the worker node should use to contact controller nodes (https://ip:port)
# In HA configurations this should be an external DNS record or loadbalancer in front of the control nodes.
# However, it is also possible to point directly to a single control node.
export CONTROLLER_ENDPOINT=

# Specify the version (vX.Y.Z) of Kubernetes assets to deploy
export K8S_RKT_VER=v1.5.6_coreos.0
export K8S_VER=v1.5.6

# Hyperkube image repository to use.
export HYPERKUBE_IMAGE_REPO=quay.io/coreos/hyperkube

# The IP address of the cluster DNS service.
# This must be the same DNS_SERVICE_IP used when configuring the controller nodes.
export DNS_SERVICE_IP=10.3.0.10

# The HTTP(S) host serving the necessary Kubernetes artifacts
export ARTIFACT_URL=

# The above settings can optionally be overridden using an environment file:
ENV_FILE=/run/coreos-kubernetes/options.env

# -------------

function template {
	# use a heredoc so the quoting & whitespace in the
	# downloaded artifact is preserved, but env variables
	# can still be evaluated
	eval "cat <<EOF
$(curl --silent -L "${ARTIFACT_URL}/$1")
EOF
" > $2
}

function init_config {
	local REQUIRED=( 'ADVERTISE_IP' 'ETCD_ENDPOINTS' 'CONTROLLER_ENDPOINT' 'DNS_SERVICE_IP' 'K8S_VER' 'ARTIFACT_URL' )

	if [ -f $ENV_FILE ]; then
		export $(cat $ENV_FILE | xargs)
	fi

	if [ -z $ADVERTISE_IP ]; then
		export ADVERTISE_IP=$(awk -F= '/COREOS_PRIVATE_IPV4/ {print $2}' /etc/environment)
	fi

	for REQ in "${REQUIRED[@]}"; do
		if [ -z "$(eval echo \$$REQ)" ]; then
			echo "Missing required config value: ${REQ}"
			exit 1
		fi
	done
}

function init_docker {
	local TEMPLATE=/etc/systemd/system/docker.service.d/40-flannel.conf
	[ -f $TEMPLATE ] || {
		echo "TEMPLATE: $TEMPLATE"
		mkdir -p $(dirname $TEMPLATE)
		cat << EOF > $TEMPLATE
[Unit]
Requires=flanneld.service
After=flanneld.service
EOF
	}

	# reload now before docker commands are run in later
	# init steps or dockerd will start before flanneld
	systemctl daemon-reload
}

function init_templates {
	local TEMPLATE=/etc/systemd/system/kubelet.service
	[ -f $TEMPLATE ] || {
		echo "TEMPLATE: $TEMPLATE"
		mkdir -p $(dirname $TEMPLATE)
		cat << EOF > $TEMPLATE
[Service]
Environment=KUBELET_VERSION=${K8S_RKT_VER}
Environment=KUBELET_ACI=${HYPERKUBE_IMAGE_REPO}
Environment="RKT_OPTS=--volume dns,kind=host,source=/etc/resolv.conf \
  --mount volume=dns,target=/etc/resolv.conf \
  --volume rkt,kind=host,source=/opt/bin/host-rkt \
  --mount volume=rkt,target=/usr/bin/rkt \
  --volume var-lib-rkt,kind=host,source=/var/lib/rkt \
  --mount volume=var-lib-rkt,target=/var/lib/rkt \
  --volume stage,kind=host,source=/tmp \
  --mount volume=stage,target=/tmp \
  --volume var-log,kind=host,source=/var/log \
  --mount volume=var-log,target=/var/log"
ExecStartPre=/usr/bin/mkdir -p /etc/kubernetes/manifests
ExecStartPre=/usr/bin/mkdir -p /var/log/containers
ExecStartPre=/usr/bin/mkdir -p /opt/bin/host-rkt
ExecStart=/usr/lib/coreos/kubelet-wrapper \
  --api_servers=${CONTROLLER_ENDPOINT} \
  --register-node=true \
  --allow-privileged=true \
  --rkt-path=/usr/bin/rkt \
  --rkt-stage1-image=coreos.com/rkt/stage1-coreos \
  --config=/etc/kubernetes/manifests \
  --cluster_dns=${DNS_SERVICE_IP} \
  --cluster_domain=cluster.local \
  --cloud-provider=aws \
  --kubeconfig=/etc/kubernetes/worker-kubeconfig.yaml \
  --tls-cert-file=/etc/kubernetes/ssl/worker.pem \
  --tls-private-key-file=/etc/kubernetes/ssl/worker-key.pem
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
	}

	mkdir -p /etc/kubernetes/manifests
	template manifests/worker/kubeconfig /etc/kubernetes/worker-kubeconfig.yaml
	template manifests/worker/kube-proxy.yaml /etc/kubernetes/manifests/kube-proxy.yaml

	local TEMPLATE=/run/flannel/options.env
	[ -f $TEMPLATE ] || {
		echo "TEMPLATE: $TEMPLATE"
		mkdir -p $(dirname $TEMPLATE)
		cat << EOF > $TEMPLATE
FLANNELD_IFACE=$ADVERTISE_IP
FLANNELD_ETCD_ENDPOINTS=$ETCD_ENDPOINTS
EOF
	}

}

init_config
init_templates
init_docker

systemctl daemon-reload
systemctl stop update-engine; systemctl mask update-engine
echo "REBOOT_STRATEGY=off" >> /etc/coreos/update.conf

systemctl enable kubelet; systemctl start kubelet
systemctl start rpc-statd
