#!/bin/bash
# ^^^ This line is load-bearing. Cloud-init reads the first line to decide how
# to handle the payload. Without a shebang it logs
#   "Unhandled non-multipart (text/x-not-multipart) userdata"
# and discards the entire script — silently, with the instance still passing
# both EC2 status checks.
#
# Boot-time provisioning for the web tier. Runs as root on FIRST BOOT ONLY.
# Amazon Linux 2023 — aws-cli v2 is preinstalled, httpd is not.

set -euo pipefail

BUCKET="REPLACE-WITH-YOUR-BUCKET-NAME"
KEY="index.html"
DOCROOT="/var/www/html"

# --- web server ---------------------------------------------------------
dnf install -y httpd
systemctl enable --now httpd

# --- pull site content from the private bucket --------------------------
# No credentials on disk. This works because of the instance profile attached
# to the launch template, which grants s3:GetObject on this bucket only.
#
# If this fails, `set -e` aborts here — but httpd is already running above,
# which means Apache serves its default "It works!" page on an empty docroot
# and returns 200. A health check on "/" would pass on a broken deploy.
# Fail loudly instead.
if ! aws s3 cp "s3://${BUCKET}/${KEY}" "${DOCROOT}/index.html"; then
  echo "FATAL: could not fetch s3://${BUCKET}/${KEY}" >&2
  # Make the failure visible to the load balancer rather than hiding it
  # behind Apache's welcome page.
  systemctl stop httpd
  exit 1
fi

# --- stamp the page with which instance served it -----------------------
# IMDSv2: get a token first, then use it on every metadata request.
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
          -H "X-aws-ec2-metadata-token-ttl-seconds: 300")

INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" \
          http://169.254.169.254/latest/meta-data/instance-id)

AZ=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" \
          http://169.254.169.254/latest/meta-data/placement/availability-zone)

sed -i "s|__INSTANCE_ID__|${INSTANCE_ID}|g; s|__AZ__|${AZ}|g" \
          "${DOCROOT}/index.html"

# --- deploy marker for a real health check ------------------------------
# Health checks should hit a path that only exists if the deploy succeeded,
# not "/" — which Apache will happily answer with its default page.
printf 'ok\n' > "${DOCROOT}/healthz"

systemctl restart httpd
