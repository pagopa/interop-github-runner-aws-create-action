#!/usr/bin/env bash

set -euo pipefail

if [[ -z "$TARGET_ENV" ]]; then
  echo "Error: Target environment is required"
  exit 1
fi

REGISTRATION_TOKEN=$(curl -s \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${PAT_TOKEN}" \
  https://api.github.com/repos/${GITHUB_REPO}/actions/runners/registration-token | jq ".token" -r)

RUNNER_NAME="${GITHUB_RUN_ID}-${MATRIX_INDEX}"
GITHUB_REPOSITORY="https://github.com/${GITHUB_REPO}"

echo "{\"awsvpcConfiguration\":{\"assignPublicIp\":\"DISABLED\",
    \"securityGroups\":[\"${ECS_TASK_SEC_GROUP}\"],
    \"subnets\":[\"${ECS_TASK_SUBNET_ID}\"]}}" > network_config.json

CPU_ENV_CONFIG=""
MEM_ENV_CONFIG=""
MAXDURATION_ENV_CONFIG=""

if [[ -n $ECS_TASK_CPU ]]; then
  CPU_ENV_CONFIG="\"cpu\": ${ECS_TASK_CPU},"
fi
if [[ -n $ECS_TASK_MEMORY ]]; then
  MEM_ENV_CONFIG="\"memory\": ${ECS_TASK_MEMORY},"
fi
if [[ -n $ECS_TASK_MAX_DURATION_SECONDS ]]; then
  MAXDURATION_ENV_CONFIG="{\"name\":\"ECS_TASK_MAX_DURATION_SECONDS\",\"value\":\"${ECS_TASK_MAX_DURATION_SECONDS}\"},"
fi

echo "{\"containerOverrides\":[{\"name\":\"${ECS_CONTAINER_NAME}\",
      $CPU_ENV_CONFIG
      $MEM_ENV_CONFIG
      \"environment\":[
        $MAXDURATION_ENV_CONFIG
        {\"name\":\"RUNNER_NAME\",\"value\":\"${RUNNER_NAME}\"},
        {\"name\":\"GITHUB_REPOSITORY\",\"value\":\"${GITHUB_REPOSITORY}\"},
        {\"name\":\"GITHUB_TOKEN\",\"value\":\"${REGISTRATION_TOKEN}\"}]}]}" > overrides.json

GROUP="${TARGET_ENV}-${RUNNER_NAME}"

echo "Run task with GROUP:${GROUP} CLUSTER: ${ECS_CLUSTER_NAME} TASK DEF: ${ECS_TASK_DEFINITION}"
echo "OVERRIDES: $(cat overrides.json | sed -e "s/${REGISTRATION_TOKEN}/***/g")

ECS_TASK_ID=$(aws ecs run-task \
  --launch-type "FARGATE" \
  --group "$GROUP" \
  --cluster "${ECS_CLUSTER_NAME}" \
  --network-configuration file://./network_config.json \
  --task-definition "${ECS_TASK_DEFINITION}" \
  --overrides file://./overrides.json \
  | jq -r '.tasks[0].taskArn' \
  | cut -d "/" -f 3)

echo "[INFO] Started ECS task $ECS_TASK_ID"
echo "ecs_task_id=$(echo $ECS_TASK_ID)" >> $GITHUB_OUTPUT

echo "[INFO] Waiting for self-hosted runner registration"
sleep 30

GITHUB_RUNNER_ID=null
START_TIME=$(date +%s)
while [ $(( $(date +%s) - 300 )) -lt $START_TIME ]; do

  echo "[INFO] Waiting for self-hosted runner registration"

  RUNNERS_LIST=$(curl -s \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${PAT_TOKEN}" \
      https://api.github.com/repos/${GITHUB_REPO}/actions/runners)

  if [ -n "$RUNNERS_LIST" ]; then
    GITHUB_RUNNER_ID=$(echo $RUNNERS_LIST | jq -r '.runners | map(select(.name == "'$RUNNER_NAME'")) | .[].id')

    if [ -n "$GITHUB_RUNNER_ID" ]; then
      echo "[INFO] Self-hosted runner ${RUNNER_NAME} has been added to this repo"
      GITHUB_RUNNER_STATUS=$(curl -s \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${PAT_TOKEN}" \
        https://api.github.com/repos/${GITHUB_REPO}/actions/runners \
        | jq -r '.runners | map(select(.name == "'$RUNNER_NAME'")) | .[].status')
        echo "[INFO] Self-hosted runner status ${GITHUB_RUNNER_STATUS}"

      break
    fi
  fi

  sleep 10

done

if [ -z "$GITHUB_RUNNER_ID" ]; then
  echo "[ERROR] $GITHUB_RUNNER_ID is empty" >&2
  exit 1
fi

retry_count=0
max_retry=5
labels_have_been_applied=""

RUN_ID_LABEL="${TARGET_ENV}-${GITHUB_RUN_ID}"

echo "[INFO] Start loop to set label for self-hosted runner ${GITHUB_RUNNER_ID}"
while [ "$retry_count" -lt "$max_retry" ]; do
  SET_LABEL_OUTPUT=$(curl -s \
    -X PUT \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${PAT_TOKEN}" \
    https://api.github.com/repos/${GITHUB_REPO}/actions/runners/${GITHUB_RUNNER_ID}/labels \
    -d '{"labels":["run_id:'${RUN_ID_LABEL}'", "matrix_index:'${MATRIX_INDEX}'", "task_id:'${ECS_TASK_ID}'", "run_number:'${GITHUB_RUN_NUMBER}'"]}')

  echo "[INFO] Set label API call result ${SET_LABEL_OUTPUT}"

  # No-op prevents grep to exit code > 0 if no match is found
  ERROR_MESSAGE=$(echo $SET_LABEL_OUTPUT | { grep "message" || :; } )

  if [ -z "$ERROR_MESSAGE" ]; then
    echo "[INFO] Labels have been set"
    labels_have_been_applied="true"

    exit 0
  else
    echo "[INFO] Labels not yet applied"
    retry_count=$(($retry_count+1))
  fi

  sleep 5
done

if [[ -z "$labels_have_been_applied" ]]; then
  echo "[ERROR] Cannot set labels for runner"
  exit 1
fi
