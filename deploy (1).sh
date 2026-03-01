PROJECT_ID="divine-bird-488912-m8"
ZONE="asia-south1-a"
REGION="asia-south1"

# My admin IP for SSH
ADMIN_IP="35.240.138.165"

echo "Let's get this project set up."
gcloud config set project $PROJECT_ID
gcloud config set compute/zone $ZONE

# First things first: turn on the Compute API so we can make VMs.
gcloud services enable compute.googleapis.com
echo "Waiting a bit for the API to wake up..."
sleep 15

# ---- STEP 1: Create Service Account ----
echo ""
echo "Step 1: Making a service account with limited access..."

gcloud iam service-accounts create vcc-sa --display-name="VCC Service Account"

# Only give viewer access—just enough, nothing risky.
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:vcc-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/compute.viewer"

echo "Service account ready."

# ---- STEP 2: Firewall Rules ----
echo ""
echo "Step 2: Setting up firewall rules..."

# Open up HTTP traffic
gcloud compute firewall-rules create allow-http \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:80 \
  --source-ranges=0.0.0.0/0 \
  --target-tags=vcc-server \
  --priority=1000

# And HTTPS as well
gcloud compute firewall-rules create allow-https \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:443 \
  --source-ranges=0.0.0.0/0 \
  --target-tags=vcc-server \
  --priority=1000

# SSH is locked to just my IP
gcloud compute firewall-rules create allow-ssh \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:22 \
  --source-ranges="${ADMIN_IP}/32" \
  --target-tags=vcc-server \
  --priority=1000

# Deny everything else just in case
gcloud compute firewall-rules create deny-all-ingress \
  --direction=INGRESS \
  --action=DENY \
  --rules=all \
  --source-ranges=0.0.0.0/0 \
  --priority=65534

echo "Firewall rules set."

# ---- STEP 3: Instance Template ----
echo ""
echo "Step 3: Making the instance template..."

gcloud compute instance-templates create vcc-template \
  --machine-type=e2-medium \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --tags=vcc-server \
  --service-account="vcc-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --metadata=startup-script='#!/bin/bash
apt-get update -y
apt-get install -y apache2 stress
systemctl enable apache2
systemctl start apache2
echo "<h1>Hello from $(hostname)</h1>" > /var/www/html/index.html'

echo "Template is good to go."

# ---- STEP 4: Managed Instance Group ----
echo ""
echo "Step 4: Spinning up the instance group..."

gcloud compute instance-groups managed create vcc-mig \
  --template=vcc-template \
  --size=1 \
  --zone=$ZONE

echo "Waiting for the instance group to settle down..."
sleep 30

gcloud compute instance-groups managed wait-until vcc-mig \
  --stable \
  --zone=$ZONE

echo "Instance group is ready."

# ---- STEP 5: Autoscaling ----
echo ""
echo "Step 5: Setting up autoscaler..."

# Scale up if CPU goes above 60%
gcloud compute instance-groups managed set-autoscaling vcc-mig \
  --zone=$ZONE \
  --min-num-replicas=1 \
  --max-num-replicas=5 \
  --target-cpu-utilization=0.60 \
  --cool-down-period=60

echo "Autoscaler attached. It'll kick in if CPU goes over 60%."

# ---- STEP 6: Health Check + Load Balancer ----
echo ""
echo "Step 6: Getting the load balancer ready..."

# Health check first
gcloud compute health-checks create http vcc-health-check \
  --port=80 \
  --request-path="/" \
  --check-interval=10 \
  --timeout=5 \
  --healthy-threshold=2 \
  --unhealthy-threshold=3

# Backend service
gcloud compute backend-services create vcc-backend \
  --protocol=HTTP \
  --health-checks=vcc-health-check \
  --global

# Add our instance group to the backend
gcloud compute backend-services add-backend vcc-backend \
  --instance-group=vcc-mig \
  --instance-group-zone=$ZONE \
  --global

# URL map
gcloud compute url-maps create vcc-url-map \
  --default-service=vcc-backend

# HTTP proxy
gcloud compute target-http-proxies create vcc-http-proxy \
  --url-map=vcc-url-map

# Forwarding rule—the load balancer gets its public IP here
gcloud compute forwarding-rules create vcc-forwarding-rule \
  --global \
  --target-http-proxy=vcc-http-proxy \
  --ports=80

echo "Load balancer set up. It usually takes a couple of minutes for the IP to show up."

# Grab the load balancer's IP
sleep 10
LB_IP=$(gcloud compute forwarding-rules describe vcc-forwarding-rule \
  --global \
  --format="value(IPAddress)")

echo ""
echo "========================================"
echo " Setup Complete!"
echo "========================================"
echo " Project    : $PROJECT_ID"
echo " Zone       : $ZONE"
echo " LB IP      : $LB_IP"
echo " MIG        : vcc-mig (min=1, max=5)"
echo " CPU Target : 60%"
echo " SSH Access : $ADMIN_IP only"
echo "========================================"
echo ""
echo "To test autoscaling:"
echo "  1. SSH into a MIG VM"
echo "  2. Run: stress --cpu 2 --timeout 300"
echo "  3. Watch: GCP Console > Instance Groups > vcc-mig > Monitoring"
echo ""
echo "To delete everything:"
echo "  run: bash deploy.sh --delete"
echo ""
