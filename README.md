# Deploying the Swiggy-Clone-App with Terraform, Kubernetes and GitHub Actions

## PHASE 1: CONFIGURATION FILES

### STEP 1: Create an EC2 instance for Docker and SonarQube

1. **main.tf**

```hcl
resource "aws_instance" "web" {
  ami                    = "ami-0287a05f0ef0e9d9a"
  instance_type          = "t3.medium"
  key_name               = "newkey" # Removed '.pem' extension
  vpc_security_group_ids = [aws_security_group.github_action_vm_sg.id]
  user_data              = templatefile("./install.sh", {})

  tags = {
    Name = "GitHubAction-SonarQube"
  }

  root_block_device {
    volume_size = 40
  }
}

resource "aws_security_group" "github_action_vm_sg" {
  name        = "GitHubAction-VM-SG"
  description = "Allow TLS inbound traffic"

  # Idiomatic Terraform way to loop over ports
  dynamic "ingress" {
    for_each = [22, 80, 443, 8080, 9000, 3000]
    content {
      description = "Inbound traffic for port ${ingress.value}"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "GitHubAction-VM-SG"
  }
}
```

2. **provider.tf**

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.20.0" # Using '~>' is a best practice to allow minor patch updates
    }
  }
}

provider "aws" {
  region = "us-east-1"
}
```

**install.sh:**

```bash
#!/bin/bash
sudo apt update
sudo apt install fontconfig openjdk-21-jre -y
java -version         
```

### STEP 2: Clone the Code

- Clone your application's code repository onto the EC2 instance:

```bash
git clone https://github.com/UrsulaN1/swiggy-clone-app.git
```

- OR from your Windows terminal, copy project folder from your local machine to your EC2 instance:

```bash
scp -i "\path\to\newkey.pem" -r "\path\to\local\code-folder" ubuntu@<EC2_PUBLIC_IP>:/home/$USER
```

### STEP 3: Install Docker and Run the App Using a Container

- Set up Docker on the EC2 instance:

```bash
sudo apt-get update
sudo apt-get install docker.io -y
sudo usermod -aG docker $USER  # Replace with your system's username, e.g., 'ubuntu'
newgrp docker
```

## PPHASE 2: SECURITY

### STEP 1. Install SonarQube and Trivy

- Install SonarQube and Trivy on the EC2 instance to scan for vulnerabilities.

```bash
docker run -d --name sonar -p 9000:9000 sonarqube:lts-community
```

**To access:**

publicIP:9000 (by default username & password is admin)

### STEP 2. Install Trivy

```bash
sudo apt-get install wget apt-transport-https gnupg lsb-release -y
wget -qO- https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor | \ 
sudo tee /usr/share/keyrings/trivy.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" \
| sudo tee /etc/apt/sources.list.d/trivy.list
sudo apt-get update
sudo apt-get install trivy -y        
```

**To scan image using trivy:**

```bash
trivy image <imageid>
```

### STEP 3: Integrate SonarQube with your GitHub Repository

**This allows SonarQube to automatically scan your code on every pull request or commit, and push the results (like code smells, bugs, and coverage) right back into your GitHub UI.**

- It makes use of GitHub Actions

#### <u> I. Create a GitHub Token in SonarQube</u>

SonarQube needs permission to comment on your pull requests and update commit statuses in GitHub.

- Log into your SonarQube dashboard
- Click your user profile icon (top right) and go to My Account > Security.
- Under Generate Tokens:Name it something like ***swiggy-cone-app***.
- Select User Token or Global Analysis Token. Click Generate and copy the token.
- You will need this in the next step.

#### <u> II - Generate the PAT in Docker Hub</u>

- Log into your Docker Hub account.
- Click on your profile avatar in the top-right corner and select Account Settings.
- On the left sidebar, click Generate ne token.
- Give your token a description (e.g., swiggy-clone-app) and leave the access permissions as Read & Write (since your pipeline needs to push images).
- Click Generate.

CRITICAL: Copy the generated token immediately. You will not be able to see it again once you close the window.

#### <u> III - Add SonarQube and Docker Hub Secrets to GitHub</u>

To keep your SonarQube and Docker Hub credentials secure, save them as Secrets inside your GitHub repository.

- Go to your GitHub repository.
- Click on Settings > Secrets and variables > Actions.
- Click **New repository secret** and add the following two secrets:

| Secret Name | Value |
| :--- | :--- |
| **SONAR_TOKEN** | Past the generatedSonarqube token |
| **SONAR_HOST_URL** | The full URL of your SonarQube server (e.g., `http://123.45.67.89:9000`) |
| **DOCKER_USERNAME** | Past your Docker Hub username |
| **DOCKER_PASSWORD** | Paste the PAT token you copied from Docker Hub |
| **AWS_ACCESS_KEY_ID** | Paste your AWS Access Key for your IAM user |
| **AWS_SECRET_ACCESS_KEY** | Paste your AWS Secret Access Key for your IAM user |
| **AWS_ACCOUNT_ID** | Paste your 12-digit ID |

### OR Use **OIDC** instead of AWS Credetials

This completely removes the need to store long-lived AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY strings in GitHub, substituting them with dynamic, short-lived tokens valid for only a single pipeline run.

#### OIDC 1: Add GitHub as an Identity Provider in AWS

**First, you need to tell your AWS account to trust security tokens handed out by GitHub.**

- Open the AWS IAM Console.
- On the left navigation pane, select Identity Providers, then click Add Provider.
- Configure these exact settings:
  - Provider Type: OpenID Connect
  - Provider URL: [https://token.actions.githubusercontent.com]
  - Audience: sts.amazonaws.com
- Click Add Provider.

#### OIDC 2: Create the IAM Role for GitHub Actions

**Now you need to create an IAM role that your pipeline can assume.**
This role must be explicitly scoped down so only your specific GitHub repository can use it.

**In the IAM Console, navigate to Roles -> Create Role.**

- Select Custom trust policy and paste the JSON configuration below.
- Make sure to replace <YOUR_AWS_ACCOUNT_ID>, <YOUR_GITHUB_USERNAME>, and <YOUR_REPO_NAME> with your exact details:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
                },
                "StringLike": {
                    "token.actions.githubusercontent.com:sub": "repo:<YOUR_GITHUB_USERNAME>/<YOUR_REPO_NAME>:*"
                }
            }
        }
    ]
}
```

- Attach the following inline policy to the IAM role you just created:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "eks:DescribeCluster",
                "eks:ListClusters"
            ],
            "Resource": "arn:aws:eks:us-east-1:123456789012:cluster/swiggy-clone-app"
        }
    ]
}
```

#### OIDC 3: Update your build.yml File

```yaml
name: Build and Deploy Swiggy Clone App

on:
  push:
    branches:
      - main

jobs:
  build:
    name: Build and Deploy
    runs-on: ubuntu-latest
    
    # ─── ADD THE PERMISSIONS BLOCK FOR OIDC ───
    permissions:
      id-token: write   # Required for requesting the JWT OIDC token from AWS
      contents: read    # Required for actions/checkout to clone your repo

    steps:
      - name: Checkout Code
        uses: actions/checkout@v4
        with:
          fetch-depth: 0  # Shallow clones disabled for better relevancy of analysis

      # 1. SONARQUBE SCAN RUNS HERE FIRST
      - name: SonarQube Scan
        uses: sonarsource/sonarqube-scan-action@v3
        env:
          SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
          SONAR_HOST_URL: ${{ secrets.SONAR_HOST_URL }}

      # 2. SECURITY SCAN RUNS NEXT
      - name: Aqua Security Scan (Trivy)
        uses: aquasecurity/trivy-action@master
        with:
          scan-type: 'fs'

      # 3. DOCKER BUILD & PUSH RUNS ONLY IF SCANS PASS
      - name: Login to Docker Hub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKER_USERNAME }}
          password: ${{ secrets.DOCKER_PASSWORD }}

      - name: Build and push Docker images
        uses: docker/build-push-action@v6.18.0
        with:
          context: .
          push: true
          tags: ursulan1/swiggy:latest

      # 4. DEPLOYMENT TO AWS
      # - name: AWS Login
      #   uses: aws-actions/configure-aws-credentials@v6.1.0
      #   with:
      #     aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
      #     aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      #     aws-region: us-east-1

      # 4. Deployment to AWS EKS
      # UPDATED FOR OIDC: No raw Access Keys required anymore!
      - name: AWS Login via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/GitHubActions-EKS-Deploy-Role
          aws-region: us-east-1

      - name: Get EKS Credentials
        run: |
          aws eks update-kubeconfig --region us-east-1 --name swiggy-clone-app

      - name: Set up kubectl
        uses: azure/setup-kubectl@v4
        with:
          version: 'latest'

      - name: Deploy to EKS
        run: |
          kubectl apply -f deployment-and-service.yml
```

#### <u> IV. Create a SonarQube Project</u>

- In SonarQube, click Create Project (usually in the top right of the homepage).
- Choose Manually (or select GitHub if you are using SonarQube Cloud/Enterprise with the official GitHub App integration).
- Give your project a Project key and Display name (e.g., swiggy-clone-app). Keep track of this key!
- Set the main branch (e.g., main or master).

#### <u>  V. Add the SonarQube Scan to GitHub Actions</u>

**To automate code quality checks every time you push code or open a pull request.**

- Now, create a workflow file in GitHub to run the scanner whenever code is pushed or a Pull Request is opened.
- In your GitHub repository, create a new file at this exact path: .github/workflows/build.yml (see build.yml)

### STEP 4: Run Git Commands

```bash
git init
git add .
git commit -m "Add first project files"
git remote add origin https://github.com/<YOUR-GITHUB-REPO>.git
git branch -M main
git push -u origin main
```

## PHASE 3: CREATE EKS CLUSTER

### STEP 1: install kubectl on EC2

```bash
sudo apt update
sudo apt install -y curl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client
```

### STEP 2: Install AWS CLI and Clone Repo

```bash
# Download and install AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
sudo apt install -y unzip
unzip awscliv2.zip
sudo ./aws/install
aws --version

# Configure global git parameters and clone repository
git config --global user.name "Your.Name"
git config --global user.email "your.email@gmail.com"
git clone https://github.com/UrsulaN1/swiggy-clone-app.git
```

### STEP 3: Install  eksctl

```bash
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
cd /tmp
sudo mv /tmp/eksctl /bin
eksctl version
```

### STEP 4: Create IAM Role for EKS

- Craete a Role with AWS Service as trusted entity
- Select EC2 from the dropdown (or common use cases), then click Next
- Add permissions: In the search box, type ***AdministratorAccess***. Check the box next to it in the list. Click Next.
- Name and review: Name the role something easy to remember, like ***EC2-Admin-Role-For-EKS***.
- Attach the IAM Role to your EC2 instance

Give about 10 seconds for AWS to propagate the permissions, then verify it works by checking your identity:un the following command:

```bash
aws sts get-caller-identity
```

### STEP 5: Setup Kubernetes Cluster using eksctl

Run the cluster creation command. Note: This process typically takes 15 to 20 minutes to complete.

```bash
eksctl create cluster --name swiggy-clone-app \
    --region us-east-1 \
    --node-type t2.medium \
    --nodes 2
```

### STEP 6: Map GitHub OIDC Role to Kubernetes RBAC

#### 1. Register your GitHub role with the EKS cluster

(replace 123456789012 with your actual 12-digit AWS account number)

```bash
aws eks create-access-entry \
    --cluster-name swiggy-clone-app \
    --principal-arn arn:aws:iam::123456789012:role/GitHubActions-EKS-Deploy-Role \
    --region us-east-1
```

#### 2. Grant that entry full Cluster Admin permissions

```bash
aws eks associate-access-policy \
    --cluster-name swiggy-clone-app \
    --principal-arn arn:aws:iam::123456789012:role/GitHubActions-EKS-Deploy-Role \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
    --access-scope type=cluster \
    --region us-east-1
```

### STEP 7: Verify Cluster Configuration

```bash
# Update local kubeconfig context to check access
aws eks update-kubeconfig --region us-east-1 --name swiggy-clone-app

# Verify control plane and node accessibility
kubectl get nodes
kubectl get all
```

## Cleanup

### STEP 1: Delete Kubernetes Resources

Before destroying the cluster, cleanly remove the deployed application and services.

```bash
# View all active deployments and services
kubectl get all

# Delete the application deployment and service
# Note: Ensure the name matches what is defined in your deployment-and-service.yml
kubectl delete deployment swiggy-app
kubectl delete service swiggy-app
```

### STEP 2: Delete the EKS Cluster

Teardown the entire infrastructure built by eksctl. This will delete the CloudFormation stacks, worker nodes, and the control plane. (This process takes about 15 minutes).

```bash
eksctl delete cluster --name swiggy-clone-app --region us-east-1
```

### STEP 3: Clean Up Local Docker Containers (EC2/Local Runner)

```bash
# List all containers (running and stopped)
docker ps -a

# Stop and remove specific containers (replace 'xxx' with Container ID or Name)
docker stop xxx
docker rm xxx

# Optional: Fast way to purge all unused containers, networks, and images
docker system prune -a --volumes -f
```

### STEP 4: Destroy Terraform Resources

If you spun up any underlying infrastructure components (like management VMs or databases) using Terraform, destroy them last.

```Bash
terraform destroy --auto-approve
```
