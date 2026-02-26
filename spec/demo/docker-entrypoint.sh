#!/bin/bash
set -e

echo "Waiting for Zeebe to be ready..."
until curl -sf http://zeebe:9600/ready > /dev/null 2>&1; do
  sleep 2
done
echo "Zeebe is ready."

exec "$@"
