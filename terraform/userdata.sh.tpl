#!/bin/bash
set -xe

# Install/ensure nginx, cloudwatch agent, and start SSM agent (SSM agent often preinstalled on Amazon Linux 2023)
# On Amazon Linux 2023 'dnf' is present but yum is symlinked; try both where needed.

# Update packages
if command -v dnf >/dev/null 2>&1; then
  dnf -y update
  PKG_MGR="dnf"
else
  yum -y update
  PKG_MGR="yum"
fi

# Install nginx
${PKG_MGR} -y install nginx || ${PKG_MGR} -y install nginx --nobest

# Ensure nginx runs and listens on 0.0.0.0:80
systemctl enable nginx
systemctl start nginx

# Basic index page
cat > /usr/share/nginx/html/index.html <<'EOF'
<html>
  <head><title>ASG ephemeral</title></head>
  <body>
    <h1>ASG instance</h1>
    <p>Instance ID: $(curl -s http://169.254.169.254/latest/meta-data/instance-id)</p>
  </body>
</html>
EOF
chown nginx:nginx /usr/share/nginx/html/index.html

# Install CloudWatch Agent (amazon-cloudwatch-agent)
# Amazon Linux may have the package available via default repos or via SSM.
${PKG_MGR} -y install amazon-cloudwatch-agent || true

# If not installed, download the agent binary
if ! command -v amazon-cloudwatch-agent-ctl >/dev/null 2>&1; then
  # Attempt to download package (region-agnostic)
  wget -q https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm -O /tmp/amazon-cloudwatch-agent.rpm || true
  rpm -Uvh /tmp/amazon-cloudwatch-agent.rpm || true
fi

# CloudWatch agent configuration to push /var/log/messages
cat > /opt/aws/amazon-cloudwatch-agent/bin/config.json <<'JSON'
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/messages",
            "log_group_name": "${cloudwatch_log_group}",
            "log_stream_name": "{instance_id}",
            "timezone": "UTC"
          }
        ]
      }
    }
  }
}
JSON

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a stop || true
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/bin/config.json -s

# Ensure SSM agent is running (usually preinstalled). Start if systemctl unit exists
if systemctl list-unit-files | grep -q amazon-ssm-agent; then
  systemctl enable amazon-ssm-agent
  systemctl start amazon-ssm-agent
fi

# Finished.
echo "userdata: complete"
