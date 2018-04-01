#!/usr/bin/env bash

source variables

cat > ~/mycron << EOF
*/5 * * * * ${SCRIPTS_DIR}/sync_s3
*/5 * * * * ${SCRIPTS_DIR}/sync_users
EOF
crontab ~/mycron
rm ~/mycron