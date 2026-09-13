#!/usr/bin/env bash
# Build, deploy, redeploy, or tear down the CITS5503 AWS demos.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REGION="ap-southeast-2"
PROFILE=""
DEMO=""
ACTION=""
BUCKET=""
YES=false
DELETE_S3=false

usage() {
  cat <<'EOF'
Usage:
  ./manage_demo.sh --demo {1|2|3} --action {build|deploy|redeploy|teardown} [options]

Options:
  --bucket NAME       Required when deploying Demo 3; use a globally unique name.
  --profile NAME      AWS CLI profile to use (otherwise uses AWS_PROFILE/default).
  --region REGION     AWS region (default: ap-southeast-2).
  --yes               Required for teardown; confirms deletion of AWS resources.
  --delete-s3         With Demo 3 teardown, also remove its recorded S3 prefix and bucket.
  --help              Show this help.

Examples:
  ./manage_demo.sh --demo 1 --action build
  ./manage_demo.sh --demo 1 --action deploy --profile cits5503
  ./manage_demo.sh --demo 1 --action redeploy --profile cits5503
  ./manage_demo.sh --demo 2 --action teardown --yes
  ./manage_demo.sh --demo 3 --action deploy --bucket my-unique-cits5503-diabetes-bucket
  ./manage_demo.sh --demo 3 --action teardown --yes --bucket my-unique-cits5503-diabetes-bucket --delete-s3

Demo 3 deploy creates the selected bucket when it does not exist, then creates
the SageMaker execution-role stack. The Demo 3 notebook reads the bucket and
role ARN from the stack outputs.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --demo) DEMO=${2:-}; shift 2 ;;
    --action) ACTION=${2:-}; shift 2 ;;
    --bucket) BUCKET=${2:-}; shift 2 ;;
    --profile) PROFILE=${2:-}; shift 2 ;;
    --region) REGION=${2:-}; shift 2 ;;
    --yes) YES=true; shift ;;
    --delete-s3) DELETE_S3=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! "$DEMO" =~ ^[123]$ ]] || [[ ! "$ACTION" =~ ^(build|deploy|redeploy|teardown)$ ]]; then
  echo "Both --demo {1|2|3} and --action {build|deploy|redeploy|teardown} are required." >&2
  usage >&2
  exit 2
fi

AWS=(aws --region "$REGION")
if [[ -n "$PROFILE" ]]; then
  AWS+=(--profile "$PROFILE")
  export AWS_PROFILE="$PROFILE"
fi

require_command() {
  command -v "$1" >/dev/null || { echo "Required command not found: $1" >&2; exit 1; }
}

require_aws_identity() {
  require_command aws
  "${AWS[@]}" sts get-caller-identity --output text >/dev/null
}

require_confirmation() {
  if [[ "$YES" != true ]]; then
    echo "Teardown deletes AWS resources. Re-run with --yes after checking the demo number." >&2
    exit 2
  fi
}

next_command() {
  local next_action=$1
  local command="./manage_demo.sh --demo $DEMO --action $next_action"
  if [[ -n "$PROFILE" ]]; then
    command+=" --profile $PROFILE"
  fi
  if [[ "$REGION" != "ap-southeast-2" ]]; then
    command+=" --region $REGION"
  fi
  printf '%s' "$command"
}

print_next_step() {
  case "$ACTION" in
    build)
      if [[ "$DEMO" == "3" ]]; then
        printf '\nNext: %s --bucket <globally-unique-bucket-name>\n' "$(next_command deploy)"
      else
        printf '\nNext: %s\n' "$(next_command deploy)"
      fi
      ;;
    deploy|redeploy)
      if [[ "$DEMO" == "3" ]]; then
        printf '\nNext: open the Demo 3 notebook and run its cells.\n'
        printf 'After the demo: %s --yes\n' "$(next_command teardown)"
        printf 'To also remove its S3 data and bucket: %s --yes --delete-s3 --bucket %s\n' \
          "$(next_command teardown)" "${BUCKET:-<bucket-name>}"
      else
        printf '\nNext: open and run the Demo %s notebook.\n' "$DEMO"
        printf 'After the demo: %s --yes\n' "$(next_command teardown)"
      fi
      ;;
    teardown)
      printf '\nTeardown requested. Confirm the stack/resources have disappeared in the AWS Console before closing the account.\n'
      ;;
  esac
}

sam_demo() {
  local demo_dir=$1
  local stack_name=$2
  require_command sam
  require_aws_identity
  cd "$SCRIPT_DIR/$demo_dir"

  case "$ACTION" in
    build)
      sam build
      print_next_step
      ;;
    redeploy)
      sam build
      ACTION=deploy
      sam_demo "$demo_dir" "$stack_name"
      ;;
    deploy)
      if [[ -f samconfig.toml ]]; then
        sam deploy
      else
        sam deploy --guided --stack-name "$stack_name" --region "$REGION"
      fi
      print_next_step
      ;;
    teardown)
      require_confirmation
      if [[ "$DEMO" == "1" ]]; then
        local upload_bucket
        upload_bucket=$("${AWS[@]}" cloudformation describe-stacks \
          --stack-name "$stack_name" \
          --query "Stacks[0].Outputs[?OutputKey=='UploadBucketName'].OutputValue" \
          --output text)
        echo "Emptying demo bucket: $upload_bucket"
        "${AWS[@]}" s3 rm "s3://$upload_bucket" --recursive
      fi
      sam delete --stack-name "$stack_name" --region "$REGION" --no-prompts
      print_next_step
      ;;
  esac
}

demo_three() {
  local demo_dir="$SCRIPT_DIR/demo3_sagemaker_hpo"
  local stack_name="cits5503-demo3-role"
  require_aws_identity

  case "$ACTION" in
    build)
      require_command python3
      python3 -m json.tool "$demo_dir/demo3_walkthrough.ipynb" >/dev/null
      echo "Demo 3 notebook JSON is valid."
      print_next_step
      ;;
    redeploy)
      require_command python3
      python3 -m json.tool "$demo_dir/demo3_walkthrough.ipynb" >/dev/null
      echo "Demo 3 notebook JSON is valid."
      ACTION=deploy
      demo_three
      ;;
    deploy)
      if [[ -z "$BUCKET" ]]; then
        echo "Demo 3 deploy requires --bucket with a globally unique bucket name." >&2
        exit 2
      fi
      if ! "${AWS[@]}" s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
        echo "Creating S3 bucket: $BUCKET"
        "${AWS[@]}" s3api create-bucket --bucket "$BUCKET" \
          --create-bucket-configuration "LocationConstraint=$REGION"
      else
        echo "Using existing S3 bucket: $BUCKET"
      fi
      "${AWS[@]}" cloudformation deploy \
        --template-file "$demo_dir/sagemaker-execution-role.yaml" \
        --stack-name "$stack_name" \
        --parameter-overrides "BucketName=$BUCKET" \
        --capabilities CAPABILITY_IAM
      printf '\nThe Demo 3 notebook will read the bucket and role from stack %s.\n' "$stack_name"
      print_next_step
      ;;
    teardown)
      require_confirmation
      if [[ "$DELETE_S3" == true && -z "$BUCKET" ]]; then
        echo "--delete-s3 also requires --bucket so the script can remove that bucket." >&2
        exit 2
      fi
      if [[ -f "$demo_dir/.demo-state.json" ]]; then
        local state_values
        state_values=$(python3 -c '
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
for key in ("endpoint_name", "endpoint_config_name", "model_name", "bucket", "prefix"):
    print(state.get(key, ""))
' "$demo_dir/.demo-state.json")
        local endpoint_name endpoint_config_name model_name state_bucket state_prefix
        local state_lines=() state_line
        while IFS= read -r state_line; do
          state_lines+=("$state_line")
        done <<< "$state_values"
        endpoint_name=${state_lines[0]:-}
        endpoint_config_name=${state_lines[1]:-}
        model_name=${state_lines[2]:-}
        state_bucket=${state_lines[3]:-}
        state_prefix=${state_lines[4]:-}
        if [[ -n "$endpoint_name" ]]; then
          echo "Deleting SageMaker endpoint: $endpoint_name"
          "${AWS[@]}" sagemaker delete-endpoint --endpoint-name "$endpoint_name"
          "${AWS[@]}" sagemaker wait endpoint-deleted --endpoint-name "$endpoint_name"
        fi
        if [[ -n "$endpoint_config_name" ]]; then
          echo "Deleting SageMaker endpoint configuration: $endpoint_config_name"
          "${AWS[@]}" sagemaker delete-endpoint-config --endpoint-config-name "$endpoint_config_name"
        fi
        if [[ -n "$model_name" ]]; then
          echo "Deleting SageMaker model: $model_name"
          "${AWS[@]}" sagemaker delete-model --model-name "$model_name"
        fi
        if [[ "$DELETE_S3" == true && -n "$state_bucket" && -n "$state_prefix" ]]; then
          echo "Emptying Demo 3 S3 prefix: s3://$state_bucket/$state_prefix/"
          "${AWS[@]}" s3 rm "s3://$state_bucket/$state_prefix/" --recursive
        fi
      else
        echo "No Demo 3 state file found; skipping endpoint cleanup."
      fi
      "${AWS[@]}" cloudformation delete-stack --stack-name "$stack_name"
      "${AWS[@]}" cloudformation wait stack-delete-complete --stack-name "$stack_name"
      if [[ "$DELETE_S3" == true ]]; then
        "${AWS[@]}" s3 rb "s3://$BUCKET"
      fi
      if [[ -f "$demo_dir/.demo-state.json" ]]; then
        rm -f "$demo_dir/.demo-state.json"
        echo "Removed completed run state: $demo_dir/.demo-state.json"
      fi
      print_next_step
      ;;
  esac
}

case "$DEMO" in
  1) sam_demo demo1_rekognition_pipeline cits5503-demo1 ;;
  2) sam_demo demo2_bedrock_api cits5503-demo2 ;;
  3) demo_three ;;
esac
