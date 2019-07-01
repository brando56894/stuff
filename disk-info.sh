#!/usr/bin/bash

for i in `ls /dev/disk/by-id|grep wwn|grep -v part`
  do
   echo "device $i is"
   sudo smartctl -i /dev/disk/by-id/$i|head -n7|tail -n3
   echo "Capacity: $(sudo smartctl -a /dev/disk/by-id/$i|grep bytes|head -n1|awk '{print $5, $6}'|cut -c 2-8)"
   echo "Health: $(sudo smartctl -H /dev/disk/by-id/$i|head -n5|tail -n1|awk '{print $6}')"
   echo "Temperature (C): $(sudo smartctl -a /dev/disk/by-id/$i|grep -e 194 -e 190|awk '{print $10}')"
   echo ""
done

for i in `ls /dev/disk/by-id|grep Samsung_SSD_9|grep -v part|grep -v scsi`
  do
   echo "device $i is"
   sudo smartctl -i /dev/disk/by-id/$i|head -n7|tail -n3
   echo "Capacity: $(sudo smartctl -a /dev/disk/by-id/$i|grep -i "total nvm capacity"|awk '{print $5,$6}'|tr -d '['|tr -d ']')"
   echo "Health: $(sudo smartctl -H /dev/disk/by-id/$i|head -n5|tail -n1|awk '{print $6}')"
   echo "Temperature (C): $(sudo smartctl -a /dev/disk/by-id/$i|grep -i "temperature:"|awk '{print $2}')"
   echo ""
done


