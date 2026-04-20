#!/bin/bash
set -e
usage() { echo "Usage: $0 --region <region> --stack-name <name>"; exit 1; }
while [[ $# -gt 0 ]]; do
  case $1 in
    --region) REGION="$2"; shift 2 ;;
    --stack-name) STACK_NAME="$2"; shift 2 ;;
    --help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done
if [ -z "$REGION" ] || [ -z "$STACK_NAME" ]; then echo "Missing required parameters"; usage; fi
echo "Deleting OpenClaw stack: $STACK_NAME in $REGION..."
aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
echo "Waiting for stack deletion..."
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"
echo "Stack deleted successfully!"
