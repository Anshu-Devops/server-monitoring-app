#!/bin/bash

# ==========================================================
# AWS APPLICATION SERVER AUTOMATED SETUP
# Ubuntu 22.04 / 24.04
# Docker + Docker Compose + AWS CLI V2
# ==========================================================

set -Eeuo pipefail

LOG_FILE="/var/log/app-server-setup.log"

exec > >(tee -a "$LOG_FILE") 2>&1

trap 'echo "ERROR at line $LINENO. Check $LOG_FILE"; exit 1' ERR

export DEBIAN_FRONTEND=noninteractive

# Change this if your AWS resources are in another region
AWS_REGION="ap-south-1"

echo "=================================================="
echo " STARTING APPLICATION SERVER SETUP"
echo "=================================================="

# ----------------------------------------------------------
# 0. ROOT AND USER VALIDATION
# ----------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    echo "Run using: sudo bash app-server-setup.sh"
    exit 1
fi

APP_USER="${SUDO_USER:-ubuntu}"

if ! id "$APP_USER" >/dev/null 2>&1; then
    echo "ERROR: User $APP_USER does not exist."
    exit 1
fi

echo "Application user: $APP_USER"
echo "AWS Region: $AWS_REGION"

# ----------------------------------------------------------
# 1. UPDATE UBUNTU
# ----------------------------------------------------------

echo "[1/10] Updating Ubuntu packages..."

apt-get update -y
apt-get upgrade -y

apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    wget \
    unzip \
    jq

# ----------------------------------------------------------
# 2. CONFIGURE DOCKER REPOSITORY
# ----------------------------------------------------------

echo "[2/10] Configuring official Docker repository..."

install -m 0755 -d /etc/apt/keyrings

curl -fsSL \
    https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor --yes \
    -o /etc/apt/keyrings/docker.gpg

chmod 0644 /etc/apt/keyrings/docker.gpg

ARCH=$(dpkg --print-architecture)
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")

cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable
EOF

apt-get update -y

# ----------------------------------------------------------
# 3. INSTALL DOCKER ENGINE
# ----------------------------------------------------------

echo "[3/10] Installing Docker Engine..."

apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

echo "Docker packages installed."

# ----------------------------------------------------------
# 4. START CONTAINERD AND DOCKER
# ----------------------------------------------------------

echo "[4/10] Starting Docker services..."

systemctl enable containerd
systemctl enable docker

# Start containerd first
systemctl restart containerd

for i in {1..15}; do

    if systemctl is-active --quiet containerd; then
        echo "containerd is running."
        break
    fi

    echo "Waiting for containerd..."
    sleep 2

done

if ! systemctl is-active --quiet containerd; then
    echo "ERROR: containerd failed to start."
    systemctl status containerd --no-pager -l
    journalctl -u containerd -n 40 --no-pager
    exit 1
fi

# Docker startup with retries
DOCKER_STARTED=false

for attempt in {1..5}; do

    echo "Docker startup attempt $attempt/5..."

    systemctl restart docker || true

    for i in {1..10}; do

        if docker info >/dev/null 2>&1; then
            DOCKER_STARTED=true
            break
        fi

        sleep 3

    done

    if [ "$DOCKER_STARTED" = true ]; then
        break
    fi

    echo "Docker not ready. Restarting containerd..."
    systemctl restart containerd
    sleep 3

done

if [ "$DOCKER_STARTED" != true ]; then

    echo "ERROR: Docker failed to start."

    systemctl status docker --no-pager -l || true
    journalctl -u docker -n 60 --no-pager || true

    exit 1
fi

echo "Docker started successfully."

docker --version
docker compose version

# ----------------------------------------------------------
# 5. CONFIGURE DOCKER GROUP PERMISSIONS
# ----------------------------------------------------------

echo "[5/10] Configuring Docker permissions..."

getent group docker >/dev/null || groupadd docker

usermod -aG docker "$APP_USER"

echo "Application user added to Docker group."

if [ -S /var/run/docker.sock ]; then

    echo "Docker socket:"
    ls -l /var/run/docker.sock

else

    echo "ERROR: Docker socket not found."
    exit 1

fi

echo "Docker service status:"
systemctl is-active docker

echo "Docker group:"
getent group docker

# ----------------------------------------------------------
# 6. INSTALL AWS CLI VERSION 2
# ----------------------------------------------------------

echo "[6/10] Installing AWS CLI V2..."

case "$(uname -m)" in

    x86_64)
        AWS_ARCH="x86_64"
        ;;

    aarch64)
        AWS_ARCH="aarch64"
        ;;

    *)
        echo "Unsupported architecture."
        exit 1
        ;;

esac

cd /tmp

curl -fsSL \
    "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" \
    -o awscliv2.zip

unzip -oq awscliv2.zip

if [ -x /usr/local/bin/aws ]; then
    ./aws/install --update
else
    ./aws/install
fi

rm -rf /tmp/aws /tmp/awscliv2.zip

aws --version

# ----------------------------------------------------------
# 7. CONFIGURE AWS REGION
# ----------------------------------------------------------

echo "[7/10] Configuring AWS default region..."

cat > /etc/profile.d/aws-region.sh <<EOF
export AWS_DEFAULT_REGION=$AWS_REGION
export AWS_REGION=$AWS_REGION
EOF

chmod 0644 /etc/profile.d/aws-region.sh

# Configure AWS CLI default region for application user
APP_HOME=$(getent passwd "$APP_USER" | cut -d: -f6)

install -d -o "$APP_USER" -g "$APP_USER" \
    "$APP_HOME/.aws"

cat > "$APP_HOME/.aws/config" <<EOF
[default]
region = $AWS_REGION
output = json
EOF

chown "$APP_USER:$APP_USER" "$APP_HOME/.aws/config"
chmod 0600 "$APP_HOME/.aws/config"

# ----------------------------------------------------------
# 8. CREATE APPLICATION DEPLOYMENT DIRECTORY
# ----------------------------------------------------------

echo "[8/10] Creating application directories..."

APP_DIR="/opt/docker-apps"

mkdir -p \
    "$APP_DIR" \
    "$APP_DIR/logs" \
    "$APP_DIR/config" \
    "$APP_DIR/releases"

chown -R "$APP_USER:$APP_USER" "$APP_DIR"

# ----------------------------------------------------------
# 9. VERIFY DOCKER AND AWS
# ----------------------------------------------------------

echo "[9/10] Verifying installation..."

echo ""
echo "========== DOCKER VERSION =========="
docker version

echo ""
echo "========== DOCKER COMPOSE =========="
docker compose version

echo ""
echo "========== DOCKER CONTAINERS =========="
docker ps

echo ""
echo "========== AWS CLI VERSION =========="
aws --version

echo ""
echo "========== AWS IDENTITY =========="

if aws sts get-caller-identity; then

    echo "AWS IAM authentication successful."

else

    echo "WARNING: AWS authentication unavailable."
    echo "Attach an EC2 IAM instance profile."
    echo "Do not configure permanent AWS keys in this script."

fi

# ----------------------------------------------------------
# 10. FINAL VERIFICATION
# ----------------------------------------------------------

echo "[10/10] Final verification..."

systemctl is-active docker
systemctl is-active containerd

echo ""
echo "========== DOCKER GROUP =========="
id "$APP_USER"

echo ""
echo "========== APPLICATION DIRECTORY =========="
ls -ld "$APP_DIR"

echo ""
echo "========== SYSTEM INFORMATION =========="
df -h /
free -h

echo ""
echo "=================================================="
echo " APPLICATION SERVER SETUP COMPLETED"
echo "=================================================="

echo "Application user: $APP_USER"
echo "AWS Region: $AWS_REGION"
echo "Docker: $(docker --version)"
echo "AWS CLI: $(aws --version)"
echo "Docker service: $(systemctl is-active docker)"
echo "containerd: $(systemctl is-active containerd)"

echo ""
echo "Application directory: $APP_DIR"
echo "Setup log: $LOG_FILE"

echo ""
echo "IMPORTANT:"
echo "Reconnect to EC2 to refresh Docker group permissions."

echo ""
echo "=================================================="