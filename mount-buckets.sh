#!/bin/bash

BUCKETS="movies games shows requested-shows vault"

# allowing docker to access the FUSE mounts
if [[ $(grep -i "#user_allow_other" /etc/fuse.conf) == "#user_allow_other" ]];then
  echo "setting 'user_allow_other' in /etc/fuse.conf ..."
  sudo sed -i 's/#user_allow_other/user_allow_other/' /etc/fuse.conf
fi

# making sure the mountpoints exist before attempting to mount the buckets
for i in $BUCKETS;do
  if [[ $i != "requested-shows" && ! -d /mnt/idrive/$i ]];then
    echo "creating /mnt/idrive/$i since it doesn't exist..."
    sudo mkdir -m 777 /mnt/idrive/$i
  elif [[ $i == "requested-shows" && ! -d /mnt/idrive/requests ]];then
    echo "creating /mnt/idrive/requests since it doesn't exist..."
    sudo mkdir -m 777 /mnt/idrive/requests
  fi
done

# making sure the log directory exists
if [[ ! -d /var/log/rclone ]];then
  sudo mkdir /var/log/rclone
fi

# mounting the buckets
for i in $BUCKETS;do
  OPTIONS="--daemon --verbose --verbose --no-modtime --vfs-cache-mode full --transfers 8 --allow-other --log-file=/var/log/rclone/$i.log  --vfs-cache-max-size=180G  --vfs-cache-max-age=5m"
  if [[ $i == "requested-shows" ]]; then
    rclone mount $OPTIONS idrive:$i /mnt/idrive/requests
    echo
  else
    rclone mount $OPTIONS idrive:$i /mnt/idrive/$i
    echo
  fi
done

