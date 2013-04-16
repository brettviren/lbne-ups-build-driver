#!/bin/bash

# run like:
usage () {
    echo "usage: ./notes.sh build-config-file"
    exit 1
}

if [ -n "$SETUP_UPS" -o -n "$UPS_DIR" ] ; then
    echo "UPS detected.  Run from a clean shell" 1>&2
    exit 1
fi

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
echo "Products going into $proddir"

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
        run wget --no-check-certificate -o $file.log -O $file $url 
	if  [ ! -f $file ] ; then
	    fail "failed to anything from $url to $file"
	fi

	if [ ! -s $file ] ; then
	    rm -f $file
	    fail "downloaded $url to $file but it is zero length"
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
    ls -d $proddir/$pkg/v* 2>/dev/null | grep -v .version | tail -1
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

    run pushd $proddir
    run patch -p0 < $patch
    run touch $flag
    cmd popd

    if [ ! -f $flag ] ; then
	fail "failed to apply $patch"
    fi
}

builder_script () {
    local pkg=$1 ; shift
    local creates=$1 ; shift
    local script="$@" 
    
    if [ -d "$creates" -o -f "$creates" ] ; then
	idem "Already created $creates with $script"
	return
    fi

    local vd=$(ups_ver_dir $pkg)
    run pushd $vd
    run $script
    cmd popd

    if [ -d "$creates" -o -f "$creates" ] ; then
	return
    fi

    fail "failed to create $creates with $cmd"
}

builder () {
    local pkg=$1 ; shift
    local script="$@" 

    local vd=$(ups_ver_dir $pkg)
    local creates=$vd.version

    apply_patch $pkg
    builder_script $pkg $creates $script
}


###########
# Actions #
###########

# prepare the build area
do_prep () {
    assuredir $proddir $downloads
}


# UPS
# https://cdcvs.fnal.gov/redmine/projects/cet-is-public/wiki/Build_a_distributable_ups
do_ups () {

    local tarball=$(download $ups_url)

    bugs "docs: the ups-upd version 4.9.7 tarball is bz2 not tgz"
    unpack $proddir auto $tarball $proddir/ups

    builder ups ./buildUps.sh
}


# ART externals
# https://cdcvs.fnal.gov/redmine/projects/cet-is-public/wiki/Building_art_externals
do_art_ext () {

    local tarball=$(download $art_ext_url)
    unpack $proddir auto $tarball $proddir/cmake

    builder cmake ./buildCmake.sh
    builder gcc ./buildGCC.sh

    builder boost	./buildBoost.sh		$base_qual $extra_qual 
    builder python	./buildPython.sh
    builder fftw	./buildFFTW.sh		$extra_qual
    builder cppunit	./buildCppunit.sh	$extra_qual $base_qual
    builder libsigcpp	./buildLibsigcpp.sh	$extra_qual $base_qual
    builder gccxml	./buildGccxml.sh
    builder clhep	./buildClhep.sh		$extra_qual $base_qual
    builder sqlite	./buildSqlite.sh	$extra_qual
    builder libxml2	./buildLibxml2.sh	$extra_qual
    builder tbb		./buildTBB.sh           $base_qual $extra_qual
}

do_nu_ext () {
    local tarball=$(download $nu_ext_url)
    unpack $proddir auto $tarball $proddir/cry

    builder xerces_c	./buildXerces.sh	$extra_qual $base_qual
    builder cry		./buildCry.sh		$base_qual $extra_qual
    builder cstxsd	./buildCstxsd.sh

    bugs "the build script has the wrong case in Redmine docs"
    builder lhapdf	./buildLhapdf.sh	$extra_qual $base_qual
    set -x
    builder_script lhapdf $proddir/pdfsets ./getPdfSets.sh
    set +x

    builder pythia	./buildPythia.sh	$extra_qual

    builder log4cpp	./buildLog4cpp.sh	$base_qual $extra_qual
    bugs "not fixing log4cpp-config"

    builder mysql_client ./buildMysql.sh	$base_qual
    builder postgresql	./buildPostgres.sh

    builder geant4	./buildGeant4.sh	$base_qual $extra_qual
    builder_script geant4 $proddir/g4surface ./getG4DataSets.sh

    builder root	./buildRoot.sh		$exp_qual:$base_qual $extra_qual
    builder genie	./buildGenie.sh		$base_qual $extra_qual

}

do_art_suite () {
    local tarball=$(download $art_suite_url)
    unpack $proddir auto $tarball $proddir/art_suite

    builder_script art_suite "$(ups_ver_dir cetlib)" ./buildCET.sh $extra_qual $base_qual

    # hack around the fact that the installation produces the art/v*
    # directly unlike everything else so far.
    local artout="$(ups_ver_dir art)"
    if [ -z "$artout" ] ; then
	artout=$proddir/art
    fi
    builder_script art_suite $artout ./buildArt.sh $exp_qual:$base_qual $extra_qual 
}

# https://cdcvs.fnal.gov/redmine/projects/larsoftsvn/wiki/Installing_a_local_copy_of_LArSoft_and_the_external_products
do_larsoft_download () {
    local bootstrap=$(download $lar_bootstrap_url)
    local updater=$(download $lar_update_url)
    
    run chmod  +x $bootstrap $updater

    # fingers crossed:

    local larsetup=$lardir/srt/srt.sh

    if [ ! -f $larsetup ] ; then
	msg "If asked for a CVS password, enter your Fermilab \"services\" one"
	run $bootstrap $lardir
    fi
    
    msg "Sourcing larsoft srt setup: $larsetup"
    source $larsetup

    if [ ! -d $lardir/releases/development/include/ ] ; then
	run $updater -rel $lar_release
    fi

    # At this point the code exists and one has to set up the larsoft
    # build environment.

    
    # declare SoftRelTools to UPS
    if [ ! -d $proddir/SoftRelTools/HEAD.version ] ; then
	run ups declare SoftRelTools HEAD \
            -r $lardir/packages/SoftRelTools/HEAD \
            -4 -m SoftRelTools.table -M ups
    fi

    # Put larsoft table file in place if it's not there already
    local lar_ups_dir=$lardir/releases/development/setup/ups
    if [ ! -d $lar_ups_dir ] ; then
	run mkdir -p $lar_ups_dir
    fi
    if [ ! -f $lar_ups_dir/larsoft.table ] ; then
	run cp larsoft.table $lar_ups_dir
    fi

    # Declare larsoft to UPS
    if [ ! -d $proddir/larsoft/development.version ] ; then
	run ups declare larsoft development \
	    -r $lardir/releases/development \
	    -4 -m larsoft.table -M setup/ups -q prof
    fi

}

do_prep
do_ups

# Common build environment setup
PRODUCTS=$proddir
source $PRODUCTS/setup

do_art_ext
do_nu_ext
do_art_suite
do_larsoft_download

