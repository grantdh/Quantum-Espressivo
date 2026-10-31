#!/bin/sh
# with-ab-profile.sh PREFIX COMMAND [ARGS...]
#
# Runs COMMAND with apple-bottom's profiler on (AB_PROFILE=1). At exit apple-bottom (1.4 and
# later) writes the process's profile to PREFIX.<pid>.json; PREFIX.<pid>.started records that
# the process began. Put it between mpirun and the program, so that every rank writes its own
# file:
#
#   mpirun -np 4 scripts/with-ab-profile.sh run/ab_profile pw.x -in scf.in
#
# ab_profile.py adds up the files of a run and checks that every process that started wrote
# one, so give each run a PREFIX of its own.
prefix=$1
shift
: > "$prefix.$$.started"
AB_PROFILE=1 AB_PROFILE_JSON="$prefix.$$.json" exec "$@"
