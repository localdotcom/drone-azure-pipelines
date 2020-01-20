#!/bin/bash

# queue build pipeline
function build {
  # read build definitions into array
  IFS=",";read -ra definitions <<< "$PLUGIN_DEFINITIONS"
  for definitionId in "${definitions[@]}"; do
    # get build name by definition id
    buildName=$(curl -s -u ${PLUGIN_USER}:${PLUGIN_SECRET} -X GET "https://dev.azure.com/${org}/${project}/_apis/build/definitions/${definitionId}?api-version=${API_VERSION}" | jq -r '.name')
    echo "Running build queue for $buildName."
    # queue build pipeline and get build id
    buildId=$(curl -s -u ${PLUGIN_USER}:${PLUGIN_SECRET} -H "Content-Type: application/json" -X POST -d '{"definition":{"id":"'${definitionId}'"}}' "https://dev.azure.com/${org}/${project}/_apis/build/builds?api-version=${API_VERSION}" | jq -r '.id')
    # write buildId to a file
    echo $buildId >> build_id
    # write buildName to a file
    echo $buildName >> build_name
  done
}

# create release
function release {
  check_build
  # read release definitions and environments into array
  IFS=","
  read -ra definitions <<< "$PLUGIN_DEFINITIONS"
  read -ra environments <<< "$PLUGIN_ENVIRONMENTS"
  unset IFS
  for definitionId in "${definitions[@]}"; do
    # get release name
    releaseName=$(curl -s -u ${PLUGIN_USER}:${PLUGIN_SECRET} -X GET "https://vsrm.dev.azure.com/${org}/${project}/_apis/release/definitions/${definitionId}?api-version=${API_VERSION}" | jq -r '.name')
    # get existing environments
    envName=$(echo $(curl -s -u ${PLUGIN_USER}:${PLUGIN_SECRET} -X GET "https://vsrm.dev.azure.com/${org}/${project}/_apis/release/definitions/${definitionId}?api-version=${API_VERSION}" | jq '.environments[] | .name') |  sed -e "s/ /,/g")
    # create empty release and get release id. automation triggers will be switched to 'manual' during release creation
    releaseId=$(curl -s -u ${PLUGIN_USER}:${PLUGIN_SECRET} -H "Content-Type: application/json" -X POST -d '{"definitionId":"'${definitionId}'","manualEnvironments":['${envName[@]}']}' "https://vsrm.dev.azure.com/${org}/${project}/_apis/release/releases/?api-version=${API_VERSION}" | jq -r '.id')
    if [[ $releaseName = null ]]; then
      echo "Release definition does not exist. Define an existing definition and try again."
      exit 1
    else
      for environment in "${environments[@]}"; do
        if [[ "${envName[@]}" =~ "${environment}" ]]; then
          # get environment id and create release for selected environments
          envId=$(curl -s -u ${PLUGIN_USER}:${PLUGIN_SECRET} -X GET "https://vsrm.dev.azure.com/${org}/${project}/_apis/release/releases/${releaseId}?api-version=${API_VERSION}" | jq '.environments[] | select (.name=="'$environment'") | .id')
          echo "Creating release $releaseName for environment $environment."
          curl -s -u ${PLUGIN_USER}:${PLUGIN_SECRET} -H "Content-Type: application/json" -X PATCH -d '{"status":"inProgress"}' "https://vsrm.dev.azure.com/${org}/${project}/_apis/release/releases/${releaseId}/environments/${envId}?api-version=${API_VERSION}-preview" > /dev/null 2>&1
        else
          echo "Environment $environment does not exist. Define an existing environment and try again."
          exit 1
        fi
      done
    fi
  done
}

# check build state
function check_build {
  # cancel task if build step was skipped 
  if [[ ! -f build_id || ! -f build_name ]]; then
    echo -e "Couldn't get build properties. Seems like build step was skipped.\nRun build step and try again."
    exit 1
  else
    # read build id from file into array
    readarray -t buildIds < build_id
    # read build name from file into array
    readarray -t buildNames < build_name
    i=0
    len=${#buildIds[@]}
    while [[ $i -lt $len ]]; do
      msg=true
      until [[ "$(curl -s -u ${PLUGIN_USER}:${PLUGIN_SECRET} -H "Content-Type: application/json" -X GET https://dev.azure.com/${org}/${project}/_apis/build/builds/${buildIds[$i]}/timeline?api-version=5.1 | jq -r '.records[] | select (.type=="Stage") | .state')" = "completed" ]]; do
        # show message once per loop
        if [[ "$msg" = true ]]; then
          echo "${buildNames[$i]} in progress. Waiting..."
          msg=false
        fi
        sleep 1
      done
        # cancel task if queued build returns 'canceled' or 'failed' status
        if [[ "$(curl -s -u ${PLUGIN_USER}:${PLUGIN_SECRET} -H "Content-Type: application/json" -X GET https://dev.azure.com/${org}/${project}/_apis/build/builds/${buildIds[$i]}/timeline?api-version=5.1 | jq -r '.records[] | select (.type=="Stage") | .result')" = "canceled" ]]; then
          echo "${buildNames[$i]}: $(curl -s -u ${PLUGIN_USER}:${PLUGIN_SECRET} -H "Content-Type: application/json" -X GET https://dev.azure.com/${org}/${project}/_apis/build/builds/${buildIds[$i]}/timeline?api-version=5.1 | jq -r '.records[] | .issues[0] | .message' | sed '/build/!d' | sed '1!d')"
          exit 1
        elif [[ "$(curl -s -u ${PLUGIN_USER}:${PLUGIN_SECRET} -H "Content-Type: application/json" -X GET https://dev.azure.com/${org}/${project}/_apis/build/builds/${buildIds[$i]}/timeline?api-version=5.1 | jq -r '.records[] | select (.type=="Stage") | .result')" = "failed" ]]; then
          echo "${buildNames[$i]}: $(curl -s -u ${PLUGIN_USER}:${PLUGIN_SECRET} -H "Content-Type: application/json" -X GET https://dev.azure.com/${org}/${project}/_apis/build/builds/${buildIds[$i]}/timeline?api-version=5.1 | jq -r '.records[] | .issues[0] | .message' | sed '/Error/!d')"
          exit 1
        elif [[ "$(curl -s -u ${PLUGIN_USER}:${PLUGIN_SECRET} -H "Content-Type: application/json" -X GET https://dev.azure.com/${org}/${project}/_apis/build/builds/${buildIds[$i]}/timeline?api-version=5.1 | jq -r '.records[] | select (.type=="Stage") | .result')" = "succeededWithIssues" ]]; then
          echo "${buildNames[$i]}: $(curl -s -u ${PLUGIN_USER}:${PLUGIN_SECRET} -H "Content-Type: application/json" -X GET https://dev.azure.com/${org}/${project}/_apis/build/builds/${buildIds[$i]}/timeline?api-version=5.1 | jq -r '.records[] | .issues[0] | .message' | sed '/Warning/!d' | sed '1!d')"
          exit 1
        else
          echo "${buildNames[$i]}: Build succeeded."
        fi
      let i++
    done
  fi
}

# replace spaces with '%20'
org=$(echo "$PLUGIN_ORGANIZATION" | sed 's/ /%20/g')
project=$(echo "$PLUGIN_PROJECT" | sed 's/ /%20/g')

# conditions
if [[ -z "$PLUGIN_USER" || -z "$PLUGIN_SECRET" ]]; then
  echo "Username or secret not specified."
  exit 1 
fi

if [[ -z "$PLUGIN_PROJECT" ]]; then
  echo "Project not specified."
  exit 1
fi

if [[ -z "$PLUGIN_ORGANIZATION" ]]; then
    echo "Organization not specified."
    exit 1 
fi

if [[ -z "$PLUGIN_ACTION" ]]; then
  echo "Action not specified."
  exit 1
elif [[ "$PLUGIN_ACTION" = "build" ]]; then
  if [[ -z "$PLUGIN_DEFINITIONS" ]]; then
    echo "Build definition not specified."
    exit 1
  else
    if [[ -z "$PLUGIN_SKIP" || "$PLUGIN_SKIP" = false ]]; then
      build
    else
      set -n build
    fi
  fi
elif [[ "$PLUGIN_ACTION" = "release" ]]; then
  if [[ -z "$PLUGIN_DEFINITIONS" ]]; then
    echo "Release definition not specified."
    exit 1
  elif [[ -z "$PLUGIN_ENVIRONMENTS" ]]; then
    echo "Environment not specified."
    exit 1
  else
    if [[ -z "$PLUGIN_SKIP" || "$PLUGIN_SKIP" = false ]]; then
      release
    else
      set -n release
    fi
  fi
else
  echo "Invalid action."
  exit 1
fi