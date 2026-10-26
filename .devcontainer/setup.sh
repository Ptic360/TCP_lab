#!/usr/bin/env bash
# Runs once when the Codespace is created: installs Kathara and pre-pulls the lab image.
set -euo pipefail

echo "== Installing Kathara =="
sudo apt-get update
sudo apt-get install -y software-properties-common gnupg
sudo add-apt-repository -y ppa:katharaframework/kathara
sudo apt-get update
sudo apt-get install -y kathara

echo "== Waiting for the Docker daemon =="
for i in $(seq 30); do
    docker info >/dev/null 2>&1 && break
    sleep 2
done

if docker info >/dev/null 2>&1; then
    echo "== Pulling kathara/base =="
    docker pull kathara/base
else
    echo "WARNING: Docker daemon is not running yet. Open a new terminal later and run: docker pull kathara/base"
fi

# The GitHub web upload drops executable bits, so restore them.
chmod +x ./*.py ./*.sh 2>/dev/null || true

echo "== Setup finished. Run ./check_env.sh =="
