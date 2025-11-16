# Fresh Start Setup & Environment Sanitization

These steps let you wipe prior runs (clusters, Docker artifacts, kubeconfig) and bring the project up cleanly on Ubuntu.

## 1) Sanitize Kubernetes/k3d/Docker state

Run the following commands **before** recloning if you want a fully clean base. They stop and delete any existing clusters, remove local kubeconfig, and clear dangling Docker data.

```bash
# Remove all k3d clusters (safe if none exist)
k3d cluster list
k3d cluster delete --all

# Stop and remove any leftover Docker containers/images/networks/volumes
docker ps -a
if [ "$(docker ps -aq)" ]; then
  docker stop $(docker ps -aq)
  docker rm $(docker ps -aq)
fi
docker system prune -a --volumes

# Reset kube client state (optional if you keep other clusters)
rm -rf ~/.kube
sudo rm -rf /etc/rancher/k3s

# Restart Docker to pick up the clean slate
sudo systemctl restart docker
```

## 2) Re-clone the repository

```bash
rm -rf ~/project-v-0.2
cd ~
git clone https://github.com/<your-org>/project-v-0.2.git
cd project-v-0.2
```

## 3) Install prerequisites (once per machine)

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"  # log out/in after running this line

# k3d and kubectl
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
```

## 4) Python environment

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```

## 5) Provision the multi-cluster fabric

```bash
# Build all k3d clusters with per-cluster networks, labels, and metrics-server
./deploy/multi-cluster-setup.sh
# Use --clean to delete/recreate, or --skip-metrics to omit metrics-server during debugging
```

## 6) Launch the Digital Twin API

```bash
source .venv/bin/activate
python app.py
```

## 7) Smoke test the planner (new terminal)

```bash
source .venv/bin/activate
curl -X POST http://127.0.0.1:8080/plan \
     -H "Content-Type: application/json" \
     -d '{
           "job": {
             "metadata": {
               "name": "test-job",
               "deadline_ms": 10000,
               "origin": {"cluster": "edge-microdc", "node": "edge-node-01"}
             },
             "spec": {
               "stages": [{
                 "id": "s1",
                 "compute": {"cpu": 2, "mem_gb": 1, "duration_ms": 2000},
                 "constraints": {"arch": ["amd64"], "formats": ["native"]}
               }]
             }
           },
           "strategy": "greedy"
         }'
```

## 8) Run experiments

```bash
source .venv/bin/activate
python -m experiments.run_suite
```

Reports are written to `reports/`. Individual scripts remain available under `experiments/`.

## 9) Teardown when done

```bash
pkill -f "python app.py" || true
./deploy/multi-cluster-setup.sh --clean
docker system prune -a --volumes
```

Following these steps from a clean host gives you a reproducible, sanitized environment and the same experiment outputs used in the proofs-of-concept.
