#!/bin/sh

### common variables
# build_for_platform - only main platform
build_for_platform="$BUILD_FOR_PLATFORM"
# set script debug
debug_output=0
echo "RELEASED = $released"
echo "REPOSITORY_NAME = $rep_name"
echo "TESTING = $testing"
file_store_base='http://file-store.rosalinux.ru'
id="$ID"
is_container="$IS_CONTAINER"
key_server="pool.sks-keyservers.net"
ROSA_key="16A853E7"
regenerate_metadata="$REGENERATE_METADATA"
released="$RELEASED"
rep_name="$REPOSITORY_NAME"
repository_path="${PLATFORM_PATH}"
# save_to_platform - main or personal platform
save_to_platform="$BUILD_FOR_PLATFORM"
# Current path:
# - /home/vagrant/scripts/publish-packages
script_path="$(pwd)"
gnupg_path="${HOME}/.gnupg"
import_path="${HOME}/gnupg"
testing="$TESTING"
use_debug_repo='true'
use_file_store="$USE_FILE_STORE"
# /

_find_gpg(){
	# /usr/bin/gpg is gpg1 in ROSA (mdv)
	# but /usr/bin/gpg2 is missing on RHEL
	# Allow to set $GPG via env
	if [ -n "$GPG" ] && command -v "$GPG" 2>/dev/null >/dev/null; then : ; else
		if command -v gpg2 2>/dev/null >/dev/null
			then GPG=gpg2
			else
				if command -v gpg 2>/dev/null >/dev/null; then GPG=gpg; fi
		fi
		if ! command -v "$GPG" 2>/dev/null >/dev/null; then
			echo "Failed to find gpg!"
			exit 1
		fi
		GPG_BIN="$(command -v "$GPG")"
	fi
}

_local_gpg_setup(){
	_find_gpg
	"${GPG}" --import "${import_path}/pubring.gpg"
	"${GPG}" --import "${import_path}/secring.gpg"
	sleep 1
	KEYNAME="$("${GPG}" --list-public-keys | sed -n 3p | awk '{ print $2 }' | awk '{ sub(/.*\//, ""); print }')"
	printf '%s\n' "--> Key used to sign RPM files: $KEYNAME"
	"${GPG}" --list-keys
	rpmmacros="${HOME}/.rpmmacros"
	rm -f "$rpmmacros"
	echo "%_signature gpg"        >> "$rpmmacros"
	echo "%_gpg_name $KEYNAME"    >> "$rpmmacros"
	echo "%_gpg_path ${gnupg_path}" >> "$rpmmacros"
	echo "%_gpgbin ${GPG_BIN}"  >> "$rpmmacros"
	echo "%__gpg ${GPG_BIN}"    >> "$rpmmacros"
	echo "--> keyname: $KEYNAME"
}
