#!/bin/bash

case "$1" in
  --iurtlogdir) LOGFILE="$2/botcmd.`date +%s`.`hostname -s`.log"; shift 2 ;;
  *) LOGFILE="/dev/null" ;;
esac

touch "$LOGFILE" &>/dev/null || LOGFILE="/dev/null"

echo PID=$$

exec perl -I/usr/local/lib/perl/iurt/lib /usr/local/bin/iurt2 "$@" &>"$LOGFILE"
