#!/bin/bash
exec > /tmp/configure.log 2>&1

# First fix permissions, no matter what. See hashicorp/terraform#8811
chmod 640  /etc/ssl/server-key.pem
chown :k8s /etc/ssl/server-key.pem
set -euo pipefail
. /etc/environment.tf

# Add servers to /etc/hosts
for ((i=0;i<SERVERS;i++)); do
  echo "${IP_INT_PREFIX}.$i.1 master$i"
done >> /etc/hosts

# Enable swap
fallocate -l 4G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
if ! grep /swapfile /etc/fstab; then
	echo '/swapfile   none    swap    sw    0   0' >> /etc/fstab
fi

# Bring up tinc
systemctl enable tinc@default
systemctl start tinc@default

# Calculate IP_INT
IP_INT="${IP_INT_PREFIX}.${INDEX}.1"

# Configuring etcd
case "$STATE" in
  new)
    CLUSTER=
    for ((i=0;i<SERVERS;i++)); do
      CLUSTER="master$i=https://${IP_INT_PREFIX}.$i.1:2380,$CLUSTER"
    done

    ETCD_OPTS="--initial-cluster-state new --initial-cluster $CLUSTER  --initial-advertise-peer-urls https://$IP_INT:2380"
    ;;
  existing)
    ENDPOINTS=
    for ((i=0;i<=SERVERS;i++)); do
      [ "$i" -eq "$INDEX" ] && continue
      ENDPOINTS="http://${IP_INT_PREFIX}.$i.1:2379,$ENDPOINTS"
    done

    ETCD_OPTS="--initial-cluster-state existing"
    ;;
  *)
    echo "State $STATE is invalid, aborting" >&2
    exit 1 
esac

ETCD_SERVERS=
for ((i=0;i<SERVERS;i++)); do
  ETCD_SERVERS="$ETCD_SERVERS,https://master$i:2379"
done

cat <<EOF > /etc/environment.calc
ETCD_OPTS='$ETCD_OPTS'
ETCD_SERVERS='$ETCD_SERVERS'
IP_INT='$IP_INT'
EOF

# Enabling services here, so they don't come up unconfigured
for s in etcd k8s-apiserver k8s-controller-manager \
    k8s-kubelet k8s-proxy k8s-scheduler docker node_exporter; do
  systemctl enable "$s"
  systemctl start  "$s" --no-block
done

while ! etcdctl \
  --ca-file /etc/ssl/5pi-ca.pem \
  --cert-file /etc/ssl/server.pem \
  --key-file /etc/ssl/server-key.pem \
  --endpoint $ENDPOINTS \
  member add $(hostname) "http://$IP_INT:2380"; do
  echo "Waiting for remote etcd to be reachable"
  sleep 1
done

# Waiting for things to be ready
if [ "$STATE" = "existing" ]; then
  while ! etcdctl cluster-health; do
    echo "Waiting for cluster to become healthy"
    sleep 1
  done
fi
