#!/bin/bash -e

# Do not use trailing slashes here
SRCBASEDIR=/home/mandrake/uploads/queue
DESTBASEDIR=/home/mandrake/uploads/approved
REJECTEDDIR=/home/mandrake/uploads/rejected
LATERBASEDIR=/home/mandrake/uploads/later
DISTRO=cooker

function list() {
	echo "The following packages are currently queued:" >&2
	find -L "$SRCBASEDIR/$DISTRO" -name "*.src.rpm" |\
		sed "s@$SRCBASEDIR/$DISTRO/@@;s@\(.*\)/\([0-9]\+[^_]\+\)@\1 \2 @" |\
		sort -k2 |\
		while read media id pkg; do
			printf "%-15s %s %15s %s\n" "$media" "$id" "$pkg"
		done
}

function inspect() {
	regexp="*.src.rpm"
	if [ -n "$1" ]; then
		regexp="*$1*.src.rpm"
	fi
	for i in `find -L "$SRCBASEDIR/$DISTRO" -name "$regexp" | sed "s@$SRCBASEDIR/$DISTRO/@@" | sort`; do
		echo $i
		rpm -qp --changelog $SRCBASEDIR/$DISTRO/$i | head | sed "s/^/\t/"
		echo
	done
}

function list_approved() {
	echo "The following packages are currently approved:"
	find -L "$DESTBASEDIR/$DISTRO" -name "*.src.rpm" |\
		sed "s@$DESTBASEDIR/$DISTRO/@@;s@\(.*\)/\([0-9]\+[^_]\+\)@\1 \2 @" |\
		sort -k2 |\
		while read media id pkg; do
			printf "%-15s %s %15s %s\n" "$media" "$id" "$pkg"
		done
}

# $1 = id = package id
# $2 = dest = destination queue
# $3 = media = forced media, like "updates/"
function move() {
	id="$1"
	dest="$2"
	media="$3"
	queuename=$(basename $dest)

	echo "Searching for packages with id $id..."
	packages=$(find -L "$SRCBASEDIR/$DISTRO" -name "${id}_*.rpm")

	echo "- Found packages:"
	for pkg in $packages; do
	        echo -e "\t$pkg" | sed "s@$SRCBASEDIR/$DISTRO/@@;s/${id}_@[0-9]\+://;s/${id}_//"
	done

	echo -n "- Moving packages to $queuename... "
	for srcpath in $packages; do
	        destpath=$(echo "$srcpath" | sed "s@$SRCBASEDIR@$dest@")
		if [ -n "$media" ]; then
			destpath=$(echo "$destpath" | sed "s@\($dest\)/\(\([^/]\+/\)\{2\}\)\([^/]\+/\)@\1/\2$media@")
		fi
		mv "$srcpath" "$destpath"
	done
	echo "done."
}

#
# Parse command line
#
if [ -z "$1" ]; then
	echo "Usage: $(basename $0) --list-queued"
	echo -e "Usage: $(basename $0) --inspect [id]\n  to inspect packages changelog"
	echo "Usage: $(basename $0) --list-approved"
	echo "Usage: $(basename $0) --approve <id> [id...]"
	echo "Usage: $(basename $0) --updates <id> [id...]"
	echo "Usage: $(basename $0) --later <id> [id...]"
	echo "Usage: $(basename $0) --reject <id> [id...]"
	echo "	Where id = 20070315170513.oden.kenobi.7558, for example"
	exit 1
fi

if [ "$1" == "--list-queued" ]; then
	list
elif [ "$1" == "--inspect" ]; then
	shift
	inspect $*
elif [ "$1" == "--list-approved" ]; then
	list_approved
elif [ "$1" == "--approve" ]; then
	while [ -n "$2" ]; do
		move "$2" "$DESTBASEDIR"
		shift
	done
elif [ "$1" == "--updates" ]; then
	while [ -n "$2" ]; do
		move "$2" "$DESTBASEDIR" "updates/"
		shift
	done
elif [ "$1" == "--later" ]; then
	while [ -n "$2" ]; do
		move "$2" "$LATERBASEDIR"
		shift
	done
elif [ "$1" == "--reject" ]; then
	while [ -n "$2" ]; do
		move "$2" "$REJECTEDDIR"
		shift
	done
else
	echo "Unknow command: $1"
	exit 1
fi

