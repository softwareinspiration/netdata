#!/usr/bin/env bash

# Netdata updater utility
#
# Variables needed by script:
#  - PATH
#  - CFLAGS
#  - LDFLAGS
#  - IS_NETDATA_STATIC_BINARY
#  - NETDATA_CONFIGURE_OPTIONS
#  - REINSTALL_OPTIONS
#  - NETDATA_TARBALL_URL
#  - NETDATA_TARBALL_CHECKSUM_URL
#  - NETDATA_TARBALL_CHECKSUM
#  - NETDATA_PREFIX / NETDATA_LIB_DIR (After 1.16.1 we will only depend on lib dir)
#
# Optional environment options:
#
#  - TMPDIR (set to a usable temporary directory)
#  - NETDATA_NIGHTLIES_BASEURL (set the base url for downloading the dist tarball)
#
# Copyright: SPDX-License-Identifier: GPL-3.0-or-later
#
# Author: Paweł Krupa <paulfantom@gmail.com>
# Author: Pavlos Emm. Katsoulakis <paul@netdata.cloud>

set -e

info() {
  echo >&3 "$(date) : INFO: " "${@}"
}

error() {
  echo >&3 "$(date) : ERROR: " "${@}"
}

safe_sha256sum() {
  # Within the contexct of the installer, we only use -c option that is common between the two commands
  # We will have to reconsider if we start non-common options
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$@"
  elif command -v shasum > /dev/null 2>&1; then
    shasum -a 256 "$@"
  else
    fatal "I could not find a suitable checksum binary to use"
  fi
}

# this is what we will do if it fails (head-less only)
fatal() {
  error "FAILED TO UPDATE NETDATA : ${1}"
  exit 1
}

cleanup() {
  if [ -n "${logfile}" ]; then
    cat >&2 "${logfile}"
    rm "${logfile}"
  fi

  if [ -n "$ndtmpdir" ] && [ -d "$ndtmpdir" ]; then
    rm -rf "$ndtmpdir"
  fi
}

_cannot_use_tmpdir() {
  local testfile ret
  testfile="$(TMPDIR="${1}" mktemp -q -t netdata-test.XXXXXXXXXX)"
  ret=0

  if [ -z "${testfile}" ] ; then
    return "${ret}"
  fi

  if /bin/echo -e '#!/bin/sh\necho SUCCESS\n' > "${testfile}" ; then
    if chmod +x "${testfile}" ; then
      if [ "$("${testfile}")" = "SUCCESS" ] ; then
        ret=1
      fi
    fi
  fi

  rm -f "${testfile}"
  return "${ret}"
}

create_tmp_directory() {
  if [ -z "${TMPDIR}" ] || _cannot_use_tmpdir "${TMPDIR}" ; then
    if _cannot_use_tmpdir /tmp ; then
      if _cannot_use_tmpdir "${PWD}" ; then
        echo >&2
        echo >&2 "Unable to find a usable temprorary directory. Please set \$TMPDIR to a path that is both writable and allows execution of files and try again."
        exit 1
      else
        TMPDIR="${PWD}"
      fi
    else
      TMPDIR="/tmp"
    fi
  fi

  mktemp -d -t netdata-updater-XXXXXXXXXX
}

download() {
  url="${1}"
  dest="${2}"
  if command -v curl > /dev/null 2>&1; then
    curl -sSL --connect-timeout 10 --retry 3 "${url}" > "${dest}" || fatal "Cannot download ${url}"
  elif command -v wget > /dev/null 2>&1; then
    wget -T 15 -O - "${url}" > "${dest}" || fatal "Cannot download ${url}"
  else
    fatal "I need curl or wget to proceed, but neither is available on this system."
  fi
}

parse_version() {
  r="${1}"
  if echo "${r}" | grep -q '^v.*'; then
    # shellcheck disable=SC2001
    # XXX: Need a regex group subsitutation here.
    r="$(echo "${r}" | sed -e 's/^v\(.*\)/\1/')"
  fi

  read -r -a p <<< "$(echo "${r}" | tr '-' ' ')"

  v="${p[0]}"
  b="${p[1]}"
  _="${p[2]}" # ignore the SHA

  if [[ ! "${b}" =~ ^[0-9]+$ ]]; then
    b="0"
  fi

  read -r -a pp <<< "$(echo "${v}" | tr '.' ' ')"
  printf "%03d%03d%03d%03d" "${pp[0]}" "${pp[1]}" "${pp[2]}" "${b}"
}

get_latest_version() {
  local latest
  if [ "${RELEASE_CHANNEL}" == "stable" ]; then
    latest="$(download "https://api.github.com/repos/netdata/netdata/releases/latest" /dev/stdout | grep tag_name | cut -d'"' -f4)"
  else
    latest="$(download "$NETDATA_NIGHTLIES_BASEURL/latest-version.txt" /dev/stdout)"
  fi
  parse_version "$latest"
}

set_tarball_urls() {
  local extension="tar.gz"

  if [ "$2" == "yes" ]; then
    extension="gz.run"
  fi

  if [ "$1" = "stable" ]; then
    local latest
    # Simple version
    latest="$(download "https://api.github.com/repos/netdata/netdata/releases/latest" /dev/stdout | grep tag_name | cut -d'"' -f4)"
    export NETDATA_TARBALL_URL="https://github.com/netdata/netdata/releases/download/$latest/netdata-$latest.${extension}"
    export NETDATA_TARBALL_CHECKSUM_URL="https://github.com/netdata/netdata/releases/download/$latest/sha256sums.txt"
  else
    export NETDATA_TARBALL_URL="$NETDATA_NIGHTLIES_BASEURL/netdata-latest.${extension}"
    export NETDATA_TARBALL_CHECKSUM_URL="$NETDATA_NIGHTLIES_BASEURL/sha256sums.txt"
  fi
}

update() {
  [ -z "${logfile}" ] && info "Running on a terminal - (this script also supports running headless from crontab)"

  RUN_INSTALLER=0
  ndtmpdir=$(create_tmp_directory)
  cd "$ndtmpdir" || exit 1

  download "${NETDATA_TARBALL_CHECKSUM_URL}" "${ndtmpdir}/sha256sum.txt" >&3 2>&3

  current_version="$(command -v netdata > /dev/null && parse_version "$(netdata -v | cut -f 2 -d ' ')")"
  latest_version="$(get_latest_version)"

  # If we can't get the current version for some reason assume `0`
  current_version="${current_version:-0}"

  # If we can't get the latest version for some reason assume `0`
  latest_version="${latest_version:-0}"

  info "Current Version: ${current_version}"
  info "Latest Version: ${latest_version}"

  if [ "${latest_version}" -gt 0 ] && [ "${current_version}" -gt 0 ] && [ "${current_version}" -ge "${latest_version}" ]; then
    info "Newest version (current=${current_version} >= latest=${latest_version}) is already installed"
  elif [ -n "${NETDATA_TARBALL_CHECKSUM}" ] && grep "${NETDATA_TARBALL_CHECKSUM}" sha256sum.txt >&3 2>&3; then
    info "Newest version is already installed"
  else
    download "${NETDATA_TARBALL_URL}" "${ndtmpdir}/netdata-latest.tar.gz"
    if ! grep netdata-latest.tar.gz sha256sum.txt | safe_sha256sum -c - >&3 2>&3; then
      fatal "Tarball checksum validation failed. Stopping netdata upgrade and leaving tarball in ${ndtmpdir}"
    fi
    NEW_CHECKSUM="$(safe_sha256sum netdata-latest.tar.gz 2> /dev/null | cut -d' ' -f1)"
    tar -xf netdata-latest.tar.gz >&3 2>&3
    rm netdata-latest.tar.gz >&3 2>&3
    cd netdata-* || exit 1
    RUN_INSTALLER=1
    cd "${NETDATA_LOCAL_TARBAL_OVERRIDE}" || exit 1
  fi

  # We got the sources, run the update now
  if [ ${RUN_INSTALLER} -eq 1 ]; then
    # signal netdata to start saving its database
    # this is handy if your database is big
    possible_pids=$(pidof netdata)
    do_not_start=
    if [ -n "${possible_pids}" ]; then
      read -r -a pids_to_kill <<< "${possible_pids}"
      kill -USR1 "${pids_to_kill[@]}"
    else
      # netdata is currently not running, so do not start it after updating
      do_not_start="--dont-start-it"
    fi

    if [ -n "${NETDATA_SELECTED_DASHBOARD}" ]; then
      env="NETDATA_SELECTED_DASHBOARD=${NETDATA_SELECTED_DASHBOARD}"
    fi

    info "Re-installing netdata..."
    eval "${env} ./netdata-installer.sh ${REINSTALL_OPTIONS} --dont-wait ${do_not_start}" >&3 2>&3 || fatal "FAILED TO COMPILE/INSTALL NETDATA"

    # We no longer store checksum info here. but leave this so that we clean up all environment files upon next update.
    sed -i '/NETDATA_TARBALL/d' "${ENVIRONMENT_FILE}"

    info "Updating tarball checksum info"
    echo "${NEW_CHECKSUM}" > "${NETDATA_LIB_DIR}/netdata.tarball.checksum"
  fi

  rm -rf "${ndtmpdir}" >&3 2>&3
  [ -n "${logfile}" ] && rm "${logfile}" && logfile=

  return 0
}

logfile=
ndtmpdir=

trap cleanup EXIT

while [ -n "${1}" ]; do
  if [ "${1}" = "--not-running-from-cron" ]; then
    NETDATA_NOT_RUNNING_FROM_CRON=1
    shift 1
  else
    break
  fi
done

# Random sleep to aileviate stampede effect of Agents upgrading
# and disconnecting/reconnecting at the same time (or near to).
# But only we're not a controlling terminal (tty)
# Randomly sleep between 1s and 60m
if [ ! -t 1 ] && [ -z "${NETDATA_NOT_RUNNING_FROM_CRON}" ]; then
  sleep $(((RANDOM % 3600) + 1))s
fi

# Usually stored in /etc/netdata/.environment
: "${ENVIRONMENT_FILE:=THIS_SHOULD_BE_REPLACED_BY_INSTALLER_SCRIPT}"

# shellcheck source=/dev/null
source "${ENVIRONMENT_FILE}" || exit 1

# We dont expect to find lib dir variable on older installations, so load this path if none found
export NETDATA_LIB_DIR="${NETDATA_LIB_DIR:-${NETDATA_PREFIX}/var/lib/netdata}"

# Source the tarbal checksum, if not already available from environment (for existing installations with the old logic)
[[ -z "${NETDATA_TARBALL_CHECKSUM}" ]] && [[ -f ${NETDATA_LIB_DIR}/netdata.tarball.checksum ]] && NETDATA_TARBALL_CHECKSUM="$(cat "${NETDATA_LIB_DIR}/netdata.tarball.checksum")"

# Grab the nightlies baseurl (defaulting to our Google Storage bucket)
export NETDATA_NIGHTLIES_BASEURL="${NETDATA_NIGHTLIES_BASEURL:-https://storage.googleapis.com/netdata-nightlies}"

if [ "${INSTALL_UID}" != "$(id -u)" ]; then
  fatal "You are running this script as user with uid $(id -u). We recommend to run this script as root (user with uid 0)"
fi

if [ -t 2 ]; then
  # we are running on a terminal
  # open fd 3 and send it to stderr
  exec 3>&2
else
  # we are headless
  # create a temporary file for the log
  logfile="$(mktemp "${logfile}"/netdata-updater.log.XXXXXX)"
  # open fd 3 and send it to logfile
  exec 3> "${logfile}"
fi

set_tarball_urls "${RELEASE_CHANNEL}" "${IS_NETDATA_STATIC_BINARY}"

if [ "${IS_NETDATA_STATIC_BINARY}" == "yes" ]; then
  ndtmpdir="$(create_tmp_directory)"
  PREVDIR="$(pwd)"

  echo >&2 "Entering ${ndtmpdir}"
  cd "${ndtmpdir}" || exit 1

  download "${NETDATA_TARBALL_CHECKSUM_URL}" "${ndtmpdir}/sha256sum.txt"
  download "${NETDATA_TARBALL_URL}" "${ndtmpdir}/netdata-latest.gz.run"
  if ! grep netdata-latest.gz.run "${ndtmpdir}/sha256sum.txt" | safe_sha256sum -c - > /dev/null 2>&1; then
    fatal "Static binary checksum validation failed. Stopping netdata installation and leaving binary in ${ndtmpdir}"
  fi

  # Do not pass any options other than the accept, for now
  # shellcheck disable=SC2086
  if sh "${ndtmpdir}/netdata-latest.gz.run" --accept -- ${REINSTALL_OPTIONS}; then
    rm -r "${ndtmpdir}"
  else
    echo >&2 "NOTE: did not remove: ${ndtmpdir}"
  fi
  echo >&2 "Switching back to ${PREVDIR}"
  cd "${PREVDIR}" || exit 1
else
  # the installer updates this script - so we run and exit in a single line
  update && exit 0
fi
