#!/usr/bin/env bash
# Builds the internal-services image remotely in CodeBuild (no local Docker needed) and pushes it to ECR.
# Called by infra/30-aws-services (terraform_data.image) with: TAG BUCKET PROJECT REPO_NAME AWS_PROFILE AWS_REGION.
#
# Python wheels are downloaded HERE (from PIP_INDEX_URL, e.g. a corporate PyPI mirror; default: pypi.org) and
# installed offline in the build, so the build agent never needs access to a package index.
# Idempotent: skips the build if the tag already exists.
set -euo pipefail
: "${TAG:?}" "${BUCKET:?}" "${PROJECT:?}" "${REPO_NAME:?}" "${AWS_PROFILE:?}" "${AWS_REGION:?}"
SRC="$(cd "$(dirname "$0")/../services" && pwd)"
PIP_INDEX="${PIP_INDEX_URL:-https://pypi.org/simple}"

if aws ecr describe-images --repository-name "$REPO_NAME" --image-ids imageTag="$TAG" >/dev/null 2>&1; then
  echo "image $REPO_NAME:$TAG already exists, skipping build"; exit 0
fi

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
rsync -a --exclude wheels --exclude __pycache__ "$SRC/" "$work/src/"
python3 -m pip download -q -d "$work/src/wheels" -r "$SRC/requirements.txt" --index-url "$PIP_INDEX" \
  --platform manylinux2014_aarch64 --platform manylinux_2_17_aarch64 --platform manylinux_2_28_aarch64 \
  --python-version 3.12 --implementation cp --only-binary=:all:
(cd "$work/src" && zip -qr "$work/src.zip" .)
aws s3 cp --only-show-errors "$work/src.zip" "s3://$BUCKET/src/$TAG.zip"

id=$(aws codebuild start-build --project-name "$PROJECT" --source-location-override "$BUCKET/src/$TAG.zip" \
  --environment-variables-override "name=IMAGE_TAG,value=$TAG,type=PLAINTEXT" --query build.id --output text)
echo "CodeBuild $id started"
while true; do
  status=$(aws codebuild batch-get-builds --ids "$id" --query 'builds[0].buildStatus' --output text)
  case "$status" in
    SUCCEEDED) echo "image $REPO_NAME:$TAG pushed"; exit 0 ;;
    IN_PROGRESS) sleep 15 ;;
    *) echo "CodeBuild $id finished with $status" >&2
       aws codebuild batch-get-builds --ids "$id" --query 'builds[0].phases[?phaseStatus!=`SUCCEEDED`].[phaseType,phaseStatus,contexts[0].message]' --output text >&2
       exit 1 ;;
  esac
done
