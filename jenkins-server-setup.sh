#!/bin/bash

# ==========================================================
# JENKINS EC2 AUTOMATED SETUP
# Ubuntu 22.04 / 24.04
# Docker + Jenkins LTS + Java 21 + AWS CLI V2
# ==========================================================

set -Eeuo pipefail

LOG_FILE="/var/log/jenkins-setup.log"

exec > >(tee -a "$LOG_FILE") 2>&1

trap 'echo "ERROR at line $LINENO. Check $LOG_FILE"; exit 1' ERR

export DEBIAN_FRONTEND=noninteractive

echo "=================================================="
echo " STARTING JENKINS EC2 SETUP"
echo "=================================================="

# ----------------------------------------------------------
# 0. ROOT AND USER VALIDATION
# ----------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    echo "Run using: sudo bash server-setup.sh"
    exit 1
fi

CURRENT_USER="${SUDO_USER:-ubuntu}"

if ! id "$CURRENT_USER" >/dev/null 2>&1; then
    echo "User $CURRENT_USER does not exist."
    exit 1
fi

echo "Setup user: $CURRENT_USER"

# ----------------------------------------------------------
# 1. CONFIGURE OFFICIAL REPOSITORIES AND GPG KEYS
# ----------------------------------------------------------

echo "[1/12] Configuring official repositories..."

install -m 0755 -d /etc/apt/keyrings
install -m 0755 -d /usr/share/keyrings

# Jenkins GPG key
curl -fsSL \
    https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key \
    -o /usr/share/keyrings/jenkins-keyring.asc

chmod 0644 /usr/share/keyrings/jenkins-keyring.asc

EXPECTED_FINGERPRINT="5E386EADB55F01504CAE8BCF7198F4B714ABFC68"

ACTUAL_FINGERPRINT=$(
    gpg --show-keys --with-colons \
    /usr/share/keyrings/jenkins-keyring.asc |
    awk -F: '$1=="fpr" {print $10; exit}'
)

if [ "$ACTUAL_FINGERPRINT" != "$EXPECTED_FINGERPRINT" ]; then
    echo "Jenkins GPG fingerprint verification failed!"
    exit 1
fi

cat > /etc/apt/sources.list.d/jenkins.list <<'EOF'
deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/
EOF

echo "Jenkins repository verified."

# Docker GPG key
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg

chmod 0644 /etc/apt/keyrings/docker.gpg

ARCH=$(dpkg --print-architecture)
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")

cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable
EOF

# Adoptium GPG key
curl -fsSL \
    https://packages.adoptium.net/artifactory/api/gpg/key/public \
    | gpg --dearmor --yes -o /etc/apt/keyrings/adoptium.gpg

chmod 0644 /etc/apt/keyrings/adoptium.gpg

cat > /etc/apt/sources.list.d/adoptium.list <<EOF
deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $CODENAME main
EOF


# ----------------------------------------------------------
# 2. UPDATE UBUNTU AND INSTALL PYTHON
# ----------------------------------------------------------

echo "[2/12] Updating Ubuntu and installing Python..."

apt-get update -y
apt-get upgrade -y

apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    wget \
    unzip \
    fontconfig \
    software-properties-common \
    python3 \
    python3-venv \
    python3-pip

echo ""
echo "Python installation verified:"

python3 --version
pip3 --version

echo "Python virtual environment support:"
python3 -m venv --help >/dev/null

echo "Python 3, pip and venv installed successfully."

# ----------------------------------------------------------
# 3. INSTALL DOCKER
# ----------------------------------------------------------

echo "[3/12] Installing Docker Engine..."

apt-get update -y

apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

echo "Docker packages installed."

# ----------------------------------------------------------
# 4. START DOCKER WITH AUTOMATIC RECOVERY
# ----------------------------------------------------------

echo "[4/12] Starting Docker and containerd..."

systemctl enable containerd
systemctl enable docker

# Start containerd first
echo "Restarting containerd..."

systemctl restart containerd

for i in {1..15}; do
    if systemctl is-active --quiet containerd; then
        echo "containerd is running."
        break
    fi

    echo "Waiting for containerd... ($i/15)"
    sleep 2
done

if ! systemctl is-active --quiet containerd; then
    echo "ERROR: containerd failed."
    systemctl status containerd --no-pager -l
    journalctl -u containerd -n 40 --no-pager
    exit 1
fi

# Start Docker with retries
DOCKER_STARTED=false

for attempt in {1..5}; do

    echo "Starting Docker attempt $attempt/5..."

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

    echo "Docker not ready. Checking containerd..."
    systemctl restart containerd
    sleep 3

done

if [ "$DOCKER_STARTED" != true ]; then
    echo "ERROR: Docker could not start."

    systemctl status docker --no-pager -l || true
    journalctl -u docker -n 60 --no-pager || true

    exit 1
fi

echo "Docker is running successfully."

docker --version
docker compose version

# ----------------------------------------------------------
# 5. CONFIGURE UBUNTU DOCKER PERMISSIONS
# ----------------------------------------------------------

echo "[5/12] Configuring Ubuntu Docker permissions..."

getent group docker >/dev/null || groupadd docker

usermod -aG docker "$CURRENT_USER"

echo "Ubuntu user added to Docker group."

# Check socket ownership
if [ -S /var/run/docker.sock ]; then
    echo "Docker socket:"
    ls -l /var/run/docker.sock
else
    echo "ERROR: Docker socket not found."
    exit 1
fi

# Test Docker using the docker group without newgrp
if sg docker -c "docker ps" >/dev/null; then
    echo "Ubuntu Docker group access verified."
else
    echo "ERROR: Docker group access verification failed."
    exit 1
fi

# ----------------------------------------------------------
# 6. INSTALL JAVA 21
# ----------------------------------------------------------

echo "[6/12] Installing Java 21..."

apt-get update -y

apt-get install -y temurin-21-jre

java -version

# ----------------------------------------------------------
# 7. INSTALL JENKINS
# ----------------------------------------------------------

echo "[7/12] Installing Jenkins LTS..."

apt-get update -y

apt-get install -y jenkins

# ----------------------------------------------------------
# 8. CONFIGURE JENKINS SERVICE AND DOCKER PERMISSIONS
# ----------------------------------------------------------

echo "[8/12] Configuring Jenkins..."

usermod -aG docker jenkins

systemctl enable jenkins
systemctl restart jenkins

# Wait for Jenkins startup
JENKINS_STARTED=false

for i in {1..30}; do

    if systemctl is-active --quiet jenkins; then
        JENKINS_STARTED=true
        break
    fi

    echo "Waiting for Jenkins... ($i/30)"
    sleep 5

done

if [ "$JENKINS_STARTED" != true ]; then
    echo "ERROR: Jenkins failed to start."
    systemctl status jenkins --no-pager -l
    journalctl -u jenkins -n 50 --no-pager
    exit 1
fi

echo "Jenkins is running."

echo "Jenkins user groups:"
id jenkins

# Verify Jenkins can access Docker
if runuser -u jenkins -- docker version; then
    echo "Jenkins Docker access verified."
else
    echo "ERROR: Jenkins cannot access Docker."
    ls -l /var/run/docker.sock
    exit 1
fi

# ----------------------------------------------------------
# 9. INSTALL AWS CLI V2
# ----------------------------------------------------------

echo "[9/12] Installing AWS CLI V2..."

case "$(uname -m)" in
    x86_64)
        AWS_ARCH="x86_64"
        ;;
    aarch64)
        AWS_ARCH="aarch64"
        ;;
    *)
        echo "Unsupported EC2 architecture."
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
# 10. CREATE DOCKER PRACTICE DIRECTORY
# ----------------------------------------------------------

echo "[10/12] Creating Docker project directory..."

mkdir -p "/home/$CURRENT_USER/docker-ui-demo"

chown -R "$CURRENT_USER:$CURRENT_USER" \
    "/home/$CURRENT_USER/docker-ui-demo"

# ----------------------------------------------------------
# 11. FINAL SERVICE VERIFICATION
# ----------------------------------------------------------

echo "[11/12] Verifying Docker and Jenkins..."

systemctl is-active docker
systemctl is-active containerd
systemctl is-active jenkins

echo ""
echo "Docker:"
docker version

echo ""
echo "Docker Compose:"
docker compose version

echo ""
echo "Jenkins:"
systemctl status jenkins --no-pager -l

echo ""
echo "Ubuntu Docker access:"
sg docker -c "docker ps"

echo ""
echo "Jenkins Docker access:"
runuser -u jenkins -- docker version

# ----------------------------------------------------------
# 12. AWS AND JENKINS FINAL DETAILS
# ----------------------------------------------------------

echo "[12/12] Final configuration..."

echo ""
echo "========== AWS CLI =========="
aws --version

echo ""
echo "========== AWS IDENTITY =========="

if aws sts get-caller-identity; then
    echo "AWS authentication successful."
else
    echo "WARNING: EC2 IAM role or AWS credentials not configured."
fi

echo ""
echo "========== JENKINS ADMIN PASSWORD =========="

PASSWORD_FOUND=false

for i in {1..30}; do

    if [ -s /var/lib/jenkins/secrets/initialAdminPassword ]; then
        PASSWORD_FOUND=true
        break
    fi

    sleep 5

done

if [ "$PASSWORD_FOUND" = true ]; then
    cat /var/lib/jenkins/secrets/initialAdminPassword
else
    echo "Password not generated yet. Check Jenkins logs."
fi

echo ""
echo "========== FINAL SETUP =========="

echo "Ubuntu user: $CURRENT_USER"
echo "Jenkins user: jenkins"
echo "Docker group: configured"
echo "Docker service: $(systemctl is-active docker)"
echo "Jenkins service: $(systemctl is-active jenkins)"

echo ""
echo "Jenkins URL:"
echo "http://YOUR-EC2-PUBLIC-IP:8080"

echo ""
echo "Setup log:"
echo "$LOG_FILE"

echo ""
echo "=================================================="
echo " JENKINS EC2 SETUP COMPLETED SUCCESSFULLY"
echo "=================================================="