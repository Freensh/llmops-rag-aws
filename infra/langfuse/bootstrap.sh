#!/usr/bin/env bash
#
# One-time setup of the host, run by cloud-init on first boot (see langfuse.tf).
# Amazon Linux 2023, x86_64. Safe to run again.
#
# What it does: swap, Docker, the compose plugin, the data disk, the CloudWatch agent, and a
# systemd unit that runs update.sh at every boot.

set -euo pipefail

# shellcheck disable=SC1091
source /etc/langfuse-host.env   # BUCKET REGION SECRET_ID DATA_VOLUME_ID COMPOSE_VERSION

# 1. Swap. The memory limits in docker-compose.yml are the real protection; swap only
#    absorbs a short spike so the kernel does not have to kill something.
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
echo 'vm.swappiness=10' > /etc/sysctl.d/90-swappiness.conf
sysctl -p /etc/sysctl.d/90-swappiness.conf

# 2. Packages
dnf install -y docker jq amazon-cloudwatch-agent

# 3. The data disk: every container volume lives here, so replacing the instance keeps the data
DEVICE="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${DATA_VOLUME_ID//-/}"
for _ in $(seq 1 60); do
  [ -e "$DEVICE" ] && break
  sleep 5
done
[ -e "$DEVICE" ] || { echo "data disk $DEVICE never appeared" >&2; exit 1; }
if ! blkid "$DEVICE" > /dev/null 2>&1; then
  mkfs.xfs "$DEVICE"   # only a brand new, empty disk has no filesystem
fi
mkdir -p /data
UUID=$(blkid -s UUID -o value "$DEVICE")
grep -q "$UUID" /etc/fstab || echo "UUID=$UUID /data xfs defaults,nofail 0 2" >> /etc/fstab
mount -a

# 4. Docker, with its files on the data disk and its logs rotated
mkdir -p /data/docker /etc/docker
cat > /etc/docker/daemon.json <<'JSON'
{
  "data-root": "/data/docker",
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "3" }
}
JSON
systemctl enable --now docker

# 5. The compose plugin, checked against the checksum published with the release
PLUGIN_DIR=/usr/local/lib/docker/cli-plugins
mkdir -p "$PLUGIN_DIR"
BASE="https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}"
curl -fsSL "$BASE/docker-compose-linux-x86_64" -o "$PLUGIN_DIR/docker-compose"
EXPECTED=$(curl -fsSL "$BASE/docker-compose-linux-x86_64.sha256" | cut -d' ' -f1)
echo "$EXPECTED  $PLUGIN_DIR/docker-compose" | sha256sum -c -
chmod 755 "$PLUGIN_DIR/docker-compose"

# 6. Memory and disk metrics for the alarms
mkdir -p /opt/langfuse
aws s3 cp "s3://$BUCKET/host/cloudwatch-agent.json" /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json --region "$REGION"
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

# 7. update.sh, and a unit that runs it at every boot
aws s3 cp "s3://$BUCKET/host/update.sh" /opt/langfuse/update.sh --region "$REGION"
sed -i 's/\r$//' /opt/langfuse/update.sh
chmod 755 /opt/langfuse/update.sh

cat > /etc/systemd/system/langfuse.service <<'UNIT'
[Unit]
Description=Langfuse and the semantic cache
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=900
ExecStart=/opt/langfuse/update.sh

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now langfuse.service
