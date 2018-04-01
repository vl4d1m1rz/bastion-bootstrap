#!/usr/bin/env bash

# https://aws.amazon.com/blogs/security/how-to-record-ssh-sessions-established-through-a-bastion-host/

source variables

# Create a new folder for the log files
mkdir -p ${BASTION_LOG_DIR}

# Allow user only to access this folder and its content
chown ${USER}:${GROUP} ${BASTION_LOG_DIR}
chmod -R 770 ${BASTION_LOG_DIR}
setfacl -Rdm other:0 ${BASTION_LOG_DIR}

# Make OpenSSH execute a custom script on logins
echo -e "\nForceCommand ${LOGIN_SCRIPT}" >> /etc/ssh/sshd_config

# Block some SSH features that bastion host users could use to circumvent
# the solution
awk '!/AllowTcpForwarding/' /etc/ssh/sshd_config > temp && mv temp /etc/ssh/sshd_config
awk '!/X11Forwarding/' /etc/ssh/sshd_config > temp && mv temp /etc/ssh/sshd_config
echo "AllowTcpForwarding no" >> /etc/ssh/sshd_config
echo "X11Forwarding no" >> /etc/ssh/sshd_config

mkdir ${SCRIPTS_DIR}

cat > ${LOGIN_SCRIPT} << EOF

# Check that the SSH client did not supply a command
if [[ -z ${SSH_ORIGINAL_COMMAND} ]]; then

  # The format of log files is ${BASTION_LOG_DIR}/YYYY-MM-DD_HH-MM-SS_user
  LOG_FILE="`date --date="today" "+%Y-%m-%d_%H-%M-%S"`_`whoami`"
  LOG_DIR="${BASTION_LOG_DIR}"

  # Print a welcome message
  echo ""
  echo "NOTE: This SSH session will be recorded"
  echo "AUDIT KEY: ${LOG_FILE}"
  echo ""

  # I suffix the log file name with a random string. I explain why
  # later on.
  SUFFIX=`mktemp -u _XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX`

  # Wrap an interactive shell into "script" to record the SSH session
  script -qf --timing=${LOG_DIR}${LOG_FILE}${SUFFIX}.time ${LOG_DIR}${LOG_FILE}${SUFFIX}.data --command=/bin/bash

else

  # The "script" program could be circumvented with some commands
  # (e.g. bash, nc). Therefore, I intentionally prevent users
  # from supplying commands.

  echo "This bastion supports interactive sessions only. Do not supply a command"
  exit 1

fi

EOF

# Make the custom script executable
chmod a+x ${LOGIN_SCRIPT}

# Bastion host users could overwrite and tamper with an existing log file
# using "script" if they knew the exact file name. I take several measures
# to obfuscate the file name:
# 1. Add a random suffix to the log file name.
# 2. Prevent bastion host users from listing the folder containing log
# files.
# This is done by changing the group owner of "script" and setting GID.
chown root:${GROUP} /usr/bin/script
chmod g+s /usr/bin/script

# 3. Prevent bastion host users from viewing processes owned by other
# users, because the log file name is one of the "script"
# execution parameters.
mount -o remount,rw,hidepid=2 /proc
awk '!/proc/' /etc/fstab > temp && mv temp /etc/fstab
echo "proc /proc proc defaults,hidepid=2 0 0" >> /etc/fstab

# 4. For durable storage, the log files are copied at a regular interval to an Amazon S3 bucket
# BASTION_LOGS_BUCKET is environment variable in /etc/environment

cat > /usr/bin/bastion/sync_s3 << EOF
# Copy log files to S3 with server-side encryption enabled.
# Then, if successful, delete log files that are older than a day.
LOG_DIR="${BASTION_LOG_DIR}"
aws s3 cp $LOG_DIR s3://${BASTION_LOGS_BUCKET}/logs/ --sse --region ${REGION} --recursive && find $LOG_DIR* -mtime +1 -exec rm {} \;

EOF

chmod 700 ${SCRIPTS_DIR}/sync_s3



# Restart the SSH service to apply /etc/ssh/sshd_config modifications.
service sshd restart