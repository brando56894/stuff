#!/bin/bash

totalwidth=0
#removes any lines mentioning the CPU, if it's intel replace it but it will also ignore NICs made by intel
for i in $(lspci|grep -viE 'amd'|awk '{print $1}')
  do
	  width=$(sudo lspci -vvs $i 2>/dev/null|grep -i lnksta|grep -vi lnksta2|awk '{print $5}'|tr -d 'x' ) 
	  echo "$(sudo lspci -vvs $i 2>/dev/null|head -n1) uses $width lanes"
	  totalwidth=$((totalwidth + width))
done
echo "Total lanes used is $totalwidth"
