#!/bin/bash

set -eo pipefail

# Script to synchronise two file shares on Azure
# Authentication against Azure must be done with Managed Identities

ENVNOTSET=0
DEFAULT_SAS_DURATION="1 hour"

if [ -z $DEBUG ] || [ $DEBUG -eq 0 ]; then
  set +x
else
  set -x
fi

if [ -z $SRC_STORAGE_ACCOUNT_ID ]; then
  echo "SRC_STORAGE_ACCOUNT_ID environment variable is not specified."
  ENVNOTSET=1
fi
if [ -z $SRC_SHARE_NAME ]; then
  echo "SRC_SHARE_NAME environment variable is not specified."
  ENVNOTSET=1
fi
if [ -z $DST_STORAGE_ACCOUNT_ID ]; then
  echo "DST_STORAGE_ACCOUNT_ID environment variable is not specified."
  ENVNOTSET=1
fi
if [ -z $DST_SHARE_NAME ]; then
  echo "DST_SHARE_NAME environment variable is not specified."
  ENVNOTSET=1
fi

if [ $ENVNOTSET -eq 1 ]; then
  exit 1
fi

if [ -z $SAS_DURATION ]; then
  SAS_DURATION=$DEFAULT_SAS_DURATION
fi



SRC_STORAGE_ACCOUNT_RG_NAME=$(echo $SRC_STORAGE_ACCOUNT_ID | awk -F "/" '{print $5}')
SRC_STORAGE_ACCOUNT_SUBSCRIPTION_ID=$(echo $SRC_STORAGE_ACCOUNT_ID | awk -F "/" '{ print $3}')
SRC_STORAGE_ACCOUNT_NAME=$(echo $SRC_STORAGE_ACCOUNT_ID | awk -F "/" '{ print $9}')

SRC_LOCK_NAME="AzureBackupProtectionLock"
SRC_LOCK_ID="${SRC_STORAGE_ACCOUNT_ID/Microsoft.Storage/Microsoft.storage}/providers/Microsoft.Authorization/locks/${SRC_LOCK_NAME}"
SRC_LOCK_LEVEL="CanNotDelete"
SRC_LOCK_NOTE="Auto-created by Azure Backup for storage accounts registered with a Recovery Services Vault. This lock is intended to guard against deletion of backups due to accidental deletion of the storage account."



DST_STORAGE_ACCOUNT_RG_NAME=$(echo $DST_STORAGE_ACCOUNT_ID | awk -F "/" '{print $5}')
DST_STORAGE_ACCOUNT_SUBSCRIPTION_ID=$(echo $DST_STORAGE_ACCOUNT_ID | awk -F "/" '{print $3}')
DST_STORAGE_ACCOUNT_NAME=$(echo $DST_STORAGE_ACCOUNT_ID | awk -F "/" '{print $9}')

# Debug test
host ${SRC_STORAGE_ACCOUNT_NAME}.file.core.windows.net
host ${DST_STORAGE_ACCOUNT_NAME}.file.core.windows.net

# LOGIN
az login --identity

# Get number of snapshots
NBSNAPS=$(az storage share-rm list --storage-account $SRC_STORAGE_ACCOUNT_NAME --resource-group $SRC_STORAGE_ACCOUNT_RG_NAME --include-snapshot --subscription $SRC_STORAGE_ACCOUNT_SUBSCRIPTION_ID --query '[?snapshotTime != null || name == "services"] | length(@)')


SRC_REST_URL="https://management.azure.com/${SRC_STORAGE_ACCOUNT_ID}/fileServices/default/shares?%24filter=startswith(name%2C%20${SRC_SHARE_NAME})&%24expand=snapshots%2Cmetadata&api-version=2019-06-01"

# Max snap on account is 200
if [ $NBSNAPS -gt 190 ]; then
  MANUAL_SNAP_LIST=$(az rest --method GET --uri $SRC_REST_URL | jq '[.value[] | select(.properties.metadata.Initiator == null) | select(.properties.snapshotTime != null)] | sort_by(.properties.snapshotTime)')
  TEN_OLDER_MANUAL_SNAPS=$(echo $MANUAL_SNAP_LIST | jq -r '.[].properties.snapshotTime' | head -n10)

  # check if lock exists
  set +e
  # az lock show --ids $SRC_LOCK_ID --subscription $SRC_STORAGE_ACCOUNT_SUBSCRIPTION_ID -o none
  az lock show -n $SRC_LOCK_NAME --subscription $SRC_STORAGE_ACCOUNT_SUBSCRIPTION_ID --resource-group $SRC_STORAGE_ACCOUNT_RG_NAME --namespace "Microsoft.Storage" --resource-name $SRC_STORAGE_ACCOUNT_NAME --resource-type "storageaccounts"
  LOCK_EXISTS=$?

  set -e
  if [ $LOCK_EXISTS -eq 0 ]; then
    # Delete AzureBackup's lock
    az lock delete --subscription $SRC_STORAGE_ACCOUNT_SUBSCRIPTION_ID -n $SRC_LOCK_NAME --resource-name $SRC_STORAGE_ACCOUNT_NAME --resource-group $SRC_STORAGE_ACCOUNT_RG_NAME --namespace "Microsoft.Storage" --resource-type "storageaccounts"
  fi
  # Delete Old manual snapshots
  for snap in $TEN_OLDER_MANUAL_SNAPS; do
    if [[ $snap == "null" || $snap == "" ]]; then
      echo "Snapshot timestamp is null or empty do nothing"
    else
     az storage share-rm delete -n $SRC_SHARE_NAME -g $SRC_STORAGE_ACCOUNT_RG_NAME --storage-account $SRC_STORAGE_ACCOUNT_NAME --snapshot $snap --subscription $SRC_STORAGE_ACCOUNT_SUBSCRIPTION_ID 
    fi
  done

  # Put back the lock
  if [ $LOCK_EXISTS -eq 0 ]; then
   az lock create --subscription $SRC_STORAGE_ACCOUNT_SUBSCRIPTION_ID --name $SRC_LOCK_NAME --notes "$SRC_LOCK_NOTE" --resource-name $SRC_STORAGE_ACCOUNT_NAME --resource-group $SRC_STORAGE_ACCOUNT_RG_NAME --resource-type "Microsoft.Storage/storageaccounts" --lock-type $SRC_LOCK_LEVEL
  fi 
fi


# Create a snapshot to synchronise
SNAPTIME=$(az storage share-rm snapshot --resource-group $SRC_STORAGE_ACCOUNT_RG_NAME --name $SRC_SHARE_NAME --storage-account $SRC_STORAGE_ACCOUNT_NAME --subscription $SRC_STORAGE_ACCOUNT_SUBSCRIPTION_ID | jq '.snapshotTime')
SNAPSHOT_URI="https://${SRC_STORAGE_ACCOUNT_NAME}.file.core.windows.net/${SRC_SHARE_NAME}?snapshot=${SNAPTIME}"

# Remote fileshare exists ? If yes do a sync. If no do a copy
DST_EXISTS=$(az storage share-rm exists --name ${DST_SHARE_NAME} --resource-group ${DST_STORAGE_ACCOUNT_RG_NAME} --storage-account ${DST_STORAGE_ACCOUNT_NAME} --subscription ${DST_STORAGE_ACCOUNT_SUBSCRIPTION_ID} | jq '.exists')

# Generate short live SAS Key
SAS_END=$(date -u -d "${SAS_DURATION}" '+%Y-%m-%dT%H:%MZ')
SRC_SAS=$(az storage share generate-sas --subscription ${SRC_STORAGE_ACCOUNT_SUBSCRIPTION_ID} -n ${SRC_SHARE_NAME} --account-name ${SRC_STORAGE_ACCOUNT_NAME} --https-only --permissions rl --expiry ${SAS_END} -o tsv)
DST_SAS=$(az storage share generate-sas --subscription ${DST_STORAGE_ACCOUNT_SUBSCRIPTION_ID} -n ${DST_SHARE_NAME} --account-name ${DST_STORAGE_ACCOUNT_NAME} --https-only --permissions rwl --expiry ${SAS_END} -o tsv)

azcopy login --identity

if [ $DST_EXISTS == "true" ]; then
  SUBCOMMAND="sync"
else
  SUBCOMMAND="copy"
fi

azcopy ${SUBCOMMAND} "${SNAPSHOT_URI}&${SRC_SAS}" "https://${DST_STORAGE_ACCOUNT_NAME}.file.core.windows.net/${DST_SHARE_NAME}?${DST_SAS}" --preserve-smb-info --preserve-smb-permissions --recursive

