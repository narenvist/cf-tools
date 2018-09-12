#!/bin/bash

# cf-bg-restart.sh - Show list of instances for a particular application, inspired by bg-restage: https://github.com/orange-cloudfoundry/cf-plugin-bg-restage
# Copyright (C) 2018  Rakuten, Inc.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# Dependencies: cf, jq >= 1.5

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $(basename "$0") APP_NAME"
    exit 1
fi

log_info () { sed <<< "$@" 's/^/[INFO] /'; }
log_error () { sed <<< "$@" 's/^/[ERROR] /'; }

APP_NAME="$1"
APP_OLD="${APP_NAME}-venerable"

if [[ $(cf app "$APP_NAME" --guid 2>&1 1>/dev/null) == "App $APP_NAME not found" ]]; then
  log_error "App $APP_NAME not found"
  exit 1
else
  APP_GUID=$(cf app "$APP_NAME" --guid)
  DROPLET_GUID=$(cf curl "/v3/apps/$APP_GUID/relationships/current_droplet" | jq -r '.data.guid')

  # Create temporary directories and files
  export TMPDIR=$(mktemp -d)
  manifest_file=$(mktemp)
  empty_dir=$(mktemp -d)

  # Get manifest
  log_info "Getting manifest ..."
  cf create-app-manifest "$APP_NAME" -p "$manifest_file"

  # Rename App
  log_info "Renaming app ..."
  cf rename "$APP_NAME" "$APP_OLD"

  # Push empty app
  log_info "Pushing an empty app ..."
  touch "$empty_dir/.empty"
  cf push -f "$manifest_file" -p "$empty_dir" --no-start > /dev/null
  new_app_guid=$(cf app "$APP_NAME" --guid)

  # Copy app bits
  log_info "Copying the app bits ..."
  copy_job_guid=$(cf curl -X POST "/v2/apps/$new_app_guid/copy_bits" -d "{\"source_app_guid\":\"$APP_GUID\"}" | jq -r '.entity.guid')
  while sleep 1; do
    [[ $(cf curl "/v2/jobs/$copy_job_guid" | jq -r '.entity.status') == "finished" ]] && break
  done

  # Copy droplet
  log_info "Copying the droplet ..."
  new_droplet_guid=$(cf curl -X POST "/v3/droplets?source_guid=$DROPLET_GUID" -d "{\"relationships\": {\"app\": {\"data\": {\"guid\": \"$new_app_guid\"}}}}" | jq -r '.guid')
  while sleep 1; do
    [[ $(cf curl "/v3/droplets/$new_droplet_guid" | jq -r '.state') == "STAGED" ]] && break
  done
  log_info "Setting the droplet as current ..."
  cf curl -X PATCH "/v3/apps/$new_app_guid/relationships/current_droplet" -d "{\"data\": {\"guid\": \"$new_droplet_guid\"}}" > /dev/null

  # Start the app
  log_info "Starting the app ..."
  cf start "$APP_NAME"

  # Clean up
  log_info "Deleting the old app ..."
  cf delete -f "$APP_OLD"
  log_info "Deleting temporary files ..."
  rm -r "$TMPDIR"
fi