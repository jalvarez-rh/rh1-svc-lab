# Setup Files

Setup scripts for configuring compliance scans and ACS Central integration.

## Clone/Update rh1-svc-lab Repository

This script is part of the rh1-svc-lab repository. Clone or update the repository:

```bash
cd ~ && git clone https://github.com/jalvarez-rh/rh1-svc-lab.git || cd ~/rh1-svc-lab && git pull origin main
```

Or if the repository already exists, update it:

```bash
cd ~/rh1-svc-lab && git pull origin main
```

## Run Compliance Operator Setup Script

Run the compliance operator setup script to configure ACS Central and create compliance scan schedules:

```bash
cd ~/rh1-svc-lab/setup-files && ./compliance-op-setup.sh
```

## Quick Setup

Clone/update the rh1-svc-lab repository and run the compliance setup script in one command:

```bash
cd ~ && git clone https://github.com/jalvarez-rh/rh1-svc-lab.git 2>/dev/null || (cd ~/rh1-svc-lab && git pull origin main) && cd ~/rh1-svc-lab/setup-files && ./compliance-op-setup.sh
```
