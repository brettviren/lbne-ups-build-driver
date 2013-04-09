#!/bin/bash

# run like:
usage () {
    echo "usage: ./notes.sh build-config-file"
    exit 1
}

# try again to closely obey instructions in Redmine starting at:
# https://cdcvs.fnal.gov/redmine/projects/cet-is-public/wiki/Build_packages_required_by_art

# This script is idempotent and self-logs.  It builds out in the
# directory in which it is contained.

config=$1 ; shift
if [ -z "$config" ] ; then
    usage
fi
top=$(readlink -f $(dirname $BASH_SOURCE))
source $config

# central logging  file
log=$logdir/log.$(date '+%Y%m%d-%H%M%S')
if [ ! -d $logdir ] ; then mkdir -p $logdir ; fi # manual
date > $log
ln -sf $log $logdir/log.latest
echo "logging to $log"


# utility functions

msg () {
    echo "$@" 1>&2
    echo "$@" >> $log 2>&1
}

bugs () {
    msg "BUGS: $@"
}

fail () {
    msg "FAILURE: $@"
    exit 1
}

idem () {
    # isolate idempotency mesages in order to comment them out if desired
    msg "IDEM: $@"
}

# A quietish command
cmd () {
    local cmdline="$@"
    $cmdline >> $log 2>&1
    if [ "$?" != "0" ] ; then
	fail "$cmdline"
    fi
}
# A loud command
run () {
    local cmdline="$@"
    msg "Running $cmdline"
    cmd "$cmdline"
    msg "SUCCESS: $cmdline"
}

download () {
    local url
    for url in $@
    do
        local file=$downloads/$(basename $url)
	echo $file
        if [ -f $file ] ; then
            idem "Already downloaded: $file"
            continue
        fi
        run wget -o $file.log -O $file $url 
	if [ ! -f $file ] ; then
	    fail "failed to download $url to $file"
	fi
    done
}

assuredir () {
    local dir
    for dir in "$@" ; do
	if [ ! -d $dir ] ; then
	    run mkdir -p $dir
	else
	    idem "Directory already made: $dir"
	fi
    done
}

ups_ver_dir () {
    local pkg=$1 ; shift
    ls -d $products/$pkg/v* 2>/dev/null | grep -v .version | tail -1
}

unpack () {
    local where=$1 ; shift
    local how=$1 ; shift
    local what=$1 ; shift
    local creates=$1 ; shift

    if [ -d "$creates" ] ; then
	idem "unpack: output directory for $what already exists: $creates"
	return
    fi

    run pushd $where

    if [ "$how" = "zip" ] ; then
	run unzip $what
    elif [ "$how" = "auto" ] ; then
	if [ -n "$(echo $what | egrep '.tar.gz|.tgz')" ] ; then
	    run tar xzf $what
	elif [ -n "$(echo $what | egrep '.tar.bz2|.tbz|.tbz2')" ] ; then
	    run tar xjf $what
	else
	    fail "do not know how to automatically unpack $what"
	fi
    else
	run tar $how $what
    fi

    cmd popd

    if [ -d "$creates" ] ; then return ; fi

    fail "Failed to unpack $what by $how to $creates"
}

apply_patch () {
    local pkg=$1 ; shift
    local patch=$patchdir/$pkg.patch
    local flag=$patch.applied

    if [ ! -f $patch ] ; then
	msg "No patch file for $pkg at $patch"
	return
    fi

    if [ -f $flag ] ; then
	idem "already applied $patch"
	return
    fi

    run pushd $products
    run patch -p0 < $patch
    run touch $flag
    cmd popd

    if [ ! -f $flag ] ; then
	fail "failed to apply $patch"
    fi
}

builder () {
    local pkg=$1 ; shift
    local script="$@" 

    local vd=$(ups_ver_dir $pkg)
    local creates=$vd.version

    if [ -d "$creates" -o -f "$creates" ] ; then
	idem "Already created $creates with $script"
	return
    fi

    apply_patch $pkg

    # Common build environment setup
    PRODUCTS=$products
    source $PRODUCTS/setup

    run pushd $vd
    run $script
    cmd popd

    if [ -d "$creates" -o -f "$creates" ] ; then
	return
    fi

    fail "failed to create $creates with $cmd"
}


###########
# Actions #
###########

# prepare the build area
do_prep () {
    assuredir $products $downloads
}


# UPS
# https://cdcvs.fnal.gov/redmine/projects/cet-is-public/wiki/Build_a_distributable_ups
do_ups () {

    tarball=$(download $ups_url)

    bugs "docs: the ups-upd version 4.9.7 tarball is bz2 not tgz"
    unpack $products auto $tarball $products/ups

    builder ups ./buildUps.sh
}


# ART externals
# https://cdcvs.fnal.gov/redmine/projects/cet-is-public/wiki/Building_art_externals
do_art_ext () {

    tarball=$(download $art_ext_url)
    unpack $products auto $tarball $products/cmake

    builder cmake ./buildCmake.sh
    builder gcc ./buildGCC.sh
}


do_prep
do_ups
do_art_ext
