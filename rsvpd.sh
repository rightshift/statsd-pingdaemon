#!/bin/bash
# marlon@rightshift.biz at RightShift, Cape Town
# A server monitoring ping-daemon for logging to a statsd graphing server
# Copyright (c) 2013 Rightshift
# Licensed under The MIT License (MIT), see license.txt for copying permission. 
# Portions of this file is taken from Apokalyptik's GPL'd daemon-functions.sh (Thanks!) 
# http://blog.apokalyptik.com/2008/05/09/as-close-to-a-real-daemon-as-bash-scripts-get/

# INSTALL
# For simplicity, I have combined daemon-functions.sh and my other ping related script,
# into a single file. This can either be installed into /etc/init.d/ or placed elsewhere,
# and linked to from there. This will enable you to manipulate the service as usual.

MY_PID=$$
MY_PATH=$(readlink -f $0)
MY_ROOT=$(dirname $MY_PATH)
MY_NAME=$(basename $MY_PATH)
VAR_RUN="/var/run"
VAR_LOG="/var/log"
MY_PIDFILE="$VAR_RUN/$MY_NAME.pid"
MY_KILLFILE="$VAR_RUN/$MY_NAME.kill"
MY_ERRFILE="$VAR_LOG/$MY_NAME.err"
MY_LOGFILE="$VAR_LOG/$MY_NAME.log"
MY_WAITFILE="$VAR_RUN/$MY_NAME.wait"
MY_BLOCKFILE="$VAR_RUN/$MY_NAME.block"
SERVERLIST="/etc/rsvp_servers.conf"
# Your statsd host - must not be empty
STATSDHOST=""

pingAndLogSingleHost() {
    # ping params. Count, Interval and Wait, as per 'man ping'
	pCount=1
	pInterval=1
	pWait=2
	logDateFormat="+%F %T"
	host=$1
	timenow=$(date "$logDateFormat")

	sanePingOutput=$(ping -q -w $pWait -i $pInterval -c $pCount $host | tail -n3 | sed 's/ping//' | sed 's/rtt //' | sed 's/--- /HOST /' | sed 's/ ---//' | tr "\\n" ",")
	echo "$timenow ::: $sanePingOutput"	# logging line, remove this if not needed

	packetLoss=$(echo $sanePingOutput | grep -oP '\d+(?=% packet loss)')
	timeSlice=$(echo $sanePingOutput | cut -d '=' -f 2)
	timeMin=$(echo $timeSlice | cut -d '/' -f 1)		# after the = cut, field 1 is min, field 2 is avg, field 3 is max 
	timeMax=$(echo $timeSlice | cut -d '/' -f 2)
	timeAvg=$(echo $timeSlice | cut -d '/' -f 3)

	# sometimes, hosts fail completely, causing the cuts to misfire, and we get long useless strings
	lenCheck=${#timeAvg}
	if [ $lenCheck -gt 8 ]; then
		echo "Skipping statsd, cannot get metrics for $host"
		return 111
	fi

	# Send data to statsd server. 
	echo "stats.network.pings.$(hostname -s).${host//./_}.min $timeMin "$(date +%s) | nc $STATSDHOST 2003
	echo "stats.network.pings.$(hostname -s).${host//./_}.max $timeMax "$(date +%s) | nc $STATSDHOST 2003
	echo "stats.network.pings.$(hostname -s).${host//./_}.avg $timeAvg "$(date +%s) | nc $STATSDHOST 2003
	echo "stats.network.pings.$(hostname -s).${host//./_}.packetLossPerc $packetLoss "$(date +%s) | nc $STATSDHOST 2003
}

pingAll() {
    while [ true ];
    do
        checkforterm
        if [ ! -f $SERVERLIST ]; then
            echo "ServerList: $SERVERLIST - not found..."
            exit 1
        fi

        hostCount=$(cat $SERVERLIST | wc -l)
    
        # skip commented and empty lines 
        IFS=$'\r\n' HostAry=($(sed -e '/^$/d;' -e '/^#/d;' $SERVERLIST))
        for i in `seq $hostCount`; 
        do
            if [[ ! -z "${HostAry[$i]}" ]]; then 
                pingAndLogSingleHost ${HostAry[$i]} &
            fi
        done

        wait
        sleep 0.5
    done
}

# This function is part of Apokalyptik's GPL'd daemon-functions.sh script
# http://blog.apokalyptik.com/2008/05/09/as-close-to-a-real-daemon-as-bash-scripts-get/
function checkforterm() {
	if [ -f $MY_KILLFILE ]; then
		echo $(date)" Terminating gracefully" >> $MY_ERRFILE
		rm $MY_PIDFILE
		rm $MY_KILLFILE
		kill $MY_PID
		exit 0
	fi
	sleepcount=0
	while [ -f $MY_WAITFILE ]; do 
		let sleepcount=$sleepcount+1
		let pos=$sleepcount%10
		if [ $pos -eq 0 ]; then
			echo $(date)" Sleeping..."
			echo $(date)" Sleeping..." >> $MY_ERRFILE
		fi
		if [ -f $MY_KILLFILE ]; then
			rm $MY_WAITFILE
			checkforterm
		fi
		sleep 1
	done
}

# This function is part of Apokalyptik's GPL'd daemon-functions.sh script
# http://blog.apokalyptik.com/2008/05/09/as-close-to-a-real-daemon-as-bash-scripts-get/
function daemonize() {
	echo $MY_PID > $MY_PIDFILE
	exec 3>&-           # close stdin
	exec 2>>$MY_ERRFILE # redirect stderr
	exec 1>>$MY_LOGFILE # redirect stdout
	echo $(date)" Daemonizing" >> $MY_ERRFILE
}


# This portion is part of Apokalyptik's GPL'd daemon-functions.sh script
# http://blog.apokalyptik.com/2008/05/09/as-close-to-a-real-daemon-as-bash-scripts-get/
CR="
"
SP=" "
OIFS=$IFS

case $1 in
	pause)
		touch $MY_WAITFILE
		;;
	resume)
		rm $MY_WAITFILE
		;;
	restart)
		$0 stop
		$0 start
		;;
	start)
		if [ -f $MY_BLOCKFILE ]; then
			echo "Daemon execution has been disabled"
			exit 0
		fi
		$0 run &
		echo "Daemon Started"
		exec 3>&- # close stdin
		exec 2>&- # close stderr
		exec 1>&- # close stdout
		exit 0
		;;
	disable)
		touch $MY_BLOCKFILE
		$0 stop
		;;
	enable)
		if [ -f $MY_BLOCKFILE ]; then rm $MY_BLOCKFILE; fi
		;;
	stop)
		echo -n "Terminating daemon... "
		$0 stat 1>/dev/null 2>/dev/null
		if [ $? -ne 0 ]; then
			echo "process is not running"
			exit 0
		fi
		touch $MY_KILLFILE
		$0 stat 1>/dev/null 2>/dev/null
		ECODE=$?
		waitcount=0
		if [ "$waitcountmax" = "" ]; then waitcountmax=30; fi
		while [ $ECODE -eq 0 ]; do
			sleep 1
			let waitcount=$waitcount+1
			if [ $waitcount -lt $waitcountmax ]; then
				$0 stat 1>/dev/null 2>/dev/null
				ECODE=$?
			else
				ECODE=1
			fi
		done
		$0 stat 1>/dev/null 2>/dev/null
		if [ $? -eq 0 ]; then
			PID=$(cat $MY_PIDFILE)
			kill $PID
			rm $MY_PIDFILE
			rm $MY_KILLFILE
			echo "Process Killed"
			echo $(date)" Terminating forcefully" >> $MY_ERRFILE
			exit 0;
		else
			echo "Process exited gracefully"
		fi
		;;
	stat)
		if [ -f $MY_BLOCKFILE ]; then
			echo "Daemon execution disabled"
		fi
		if [ ! -f $MY_PIDFILE ]; then
			echo "$MY_NAME is not running"
			exit 1
		fi
		pgrep -l -f "$MY_NAME run" | grep -q -E "^$(cat $MY_PIDFILE) " 
		if [ $? -eq 0 ]; then
			echo "$MY_NAME is running with PID "$($0 pid)
			exit 0
		else
			echo "$MY_NAME is not running (PIDFILE mismatch)"
			exit 1
		fi
		;;
	log|stdout)
		if [ -f $MY_LOGFILE ]; then
			tail -f $MY_LOGFILE
		else
			echo "No stdout output yet"
		fi
		;;
	
	err|stderr)
		if [ -f $MY_ERRFILE ]; then
			tail -f $MY_ERRFILE
		else
			echo "No stderr output yet"
		fi
		;;
	pid)
		if [ -f $MY_PIDFILE ]; then
			cat $MY_PIDFILE
		else
			echo "No pidfile found"
		fi
		;;
	run)
		daemonize
        pingAll
		;;
	help|?|--help|-h)
		echo "Usage: $0 [ start | stop | restart | stat | pause | resume | disable | enable | (log|stdout) | (err|stderr) ]"
		exit 0
		;;
	*)
		echo "Invalid argument"
		echo
		$0 help
		;;
esac

