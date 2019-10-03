#!/bin/sh
set -x

printf '%s\n' '--> mdv-scripts/publish-packages: build.sh'

# set script debug
debug_output=0

released="$RELEASED"
rep_name="$REPOSITORY_NAME"
is_container="$IS_CONTAINER"
testing="$TESTING"
id="$ID"
file_store_base='http://file-store.rosalinux.ru'
# save_to_platform - main or personal platform
save_to_platform="$BUILD_FOR_PLATFORM"
# build_for_platform - only main platform
build_for_platform="$BUILD_FOR_PLATFORM"
regenerate_metadata="$REGENERATE_METADATA"
key_server="pool.sks-keyservers.net"
ROSA_key="16A853E7"

# Current path:
# - /home/vagrant/scripts/publish-packages
script_path="$(pwd)"

# Container path:
# - /home/vagrant/container
container_path="${script_path}"/../../container

# /home/vagrant/share_folder contains:
# - http://abf.rosalinux.ru/downloads/rosa2012.1/repository
# - http://abf.rosalinux.ru/downloads/akirilenko_personal/repository/rosa2012.1

repository_path="${PLATFORM_PATH}"

use_debug_repo='true'

# Checks 'released' status of platform
status='release'
if [ "$released" = 'true' ]; then
	status='updates'
fi
if [ "$testing" = 'true' ]; then
	status='testing'
	use_debug_repo='false'
fi

sign_rpm=0
gnupg_path=/root/gnupg
KEYNAME=''

if [ ! -d "$gnupg_path" ]; then
	printf '%s\n' "--> $gnupg_path does not exist, signing rpms will be not possible"
	sign_rpm=0
else
	chmod 700 "$gnupg_path"
	if [ -f "$gnupg_path"/pubring.gpg ]; then
		gpg2 --import "$gnupg_path"/pubring.gpg
		gpg2 --import ${gnupg_path}/secring.gpg
		sleep 1
		KEYNAME=`gpg2 --list-public-keys | sed -n 3p | awk '{ print $2 }' | awk '{ sub(/.*\//, ""); print }'`
		printf '%s\n' "--> Key used to sign RPM files: $KEYNAME"
		gpg2 --list-keys
		rpmmacros=~/.rpmmacros
		rm -f $rpmmacros
		echo "%_signature gpg"        >> $rpmmacros
		echo "%_gpg_name $KEYNAME"    >> $rpmmacros
		echo "%_gpg_path /root/.gnupg" >> $rpmmacros
		echo "%_gpgbin /usr/bin/gpg2"  >> $rpmmacros
		echo "%__gpg /usr/bin/gpg2"    >> $rpmmacros
		echo "--> keyname: $KEYNAME"
		sign_rpm=1
		[ -z "$KEYNAME" ] && printf '%s\n' "GPG is not imported. RPM signing disabled." && sign_rpm=0
	else
		printf '%s\n' "Your $gnupg_path/pubring.gpg file does not exist. RPM signing is disabled."
		sign_rpm=0
	fi
fi

build_repo() {
	path=$1
	arch=$2
	regenerate_metadata=$3
	start_sign_rpms=$4
	KEYNAME=$5

	if [ "$regenerate_metadata" = 'true' ]; then
		if [ "$start_sign_rpms" = '1' ]; then
			printf '%s\n' "--> Starting to re-sign rpms in $path"
			failures=0
			for i in $(find "$path" -name '*.rpm'); do
				rpm --addsign $i
				chmod 644 $i
				printf '%s\n' "--> Package $i already signed"
			done
			if [ "${failures}" = '0' ]; then
				printf '%s\n' "--> Packages in $path have been signed successfully."
			else
				printf '%s\n' "--> Packages in $path have not been signed successfully!!!"
			fi
		else
			printf '%s\n' "--> RPM signing is disabled"
		fi
	fi

	# Just to make sure newly signed and moved packages
	# are in the filesystem and are guaranteed to show
	# up in a new docker instance
	sync

	# Build repo
	printf '%s\n' "--> [$(LANG=en_US.UTF-8 date -u)] Generating repository..."

	cd "${script_path}"/
	if [ "$regenerate_metadata" != 'true' ]; then
		# genhdlist2 in rosa/omv supports "--merge" option that can be used to speed up publication process.
		# See: https://abf.io/abf/abf-ideas/issues/149
		rm -f "${path}"/media_info/{new,old}-metadata.lst
		[ -f "${container_path}"/new."${arch}".list.downloaded ] && cp -f "${container_path}"/new."${arch}".list.downloaded ${path}/media_info/new-metadata.lst
		[ -f "${container_path}"/old."${arch}".list ] && cp -f "${container_path}"/old."${arch}".list "${path}"/media_info/old-metadata.lst

		if [[ "$save_to_platform" =~ ^.*rosa-server.* ]]; then
			MAX_RETRIES=10
			WAIT_TIME=60
			retry=0
			OLD_PUBLISHER_ID="$(/usr/bin/docker ps -q --filter=ancestor=rosalab/createrepo:latest)"
			if [ -n "$OLD_PUBLISHER_ID" ]; then
				printf '%s\n' "--> Other publisher ${PUBLISHER_ID} is still running. Delay ${WAIT_TIME} sec..."
				while [ "$retry" -lt "$MAX_RETRIES" ]; do
					PUBLISHER_ID="$(/usr/bin/docker ps -q --filter=ancestor=rosalab/createrepo:latest)"
					[ -z "$PUBLISHER_ID" ] && break

					sleep "${WAIT_TIME}"
					retry=$((retry+1))
					if [ "$PUBLISHER_ID" != "$OLD_PUBLISHER_ID" ]; then
						printf '%s\n' "--> Switching from waiting for publisher ${OLD_PUBLISHER_ID} to waiting for ${PUBLISHER_ID}"
						OLD_PUBLISHER_ID="$PUBLISHER_ID"
						retry=0
					elif [ "$retry" -ge "$MAX_RETRIES" ]; then
						printf '%s\n' "---> Publisher ${PUBLISHER_ID} stuck for more than $((RETRY*WAIT_TIME)) seconds, killing"
						/usr/bin/docker stop -t 0 ${PUBLISHER_ID}
						/usr/bin/docker rm -f ${PUBLISHER_ID}
						sleep "${WAIT_TIME}"
						PUBLISHER_ID="$(/usr/bin/docker ps -q --filter=ancestor=rosalab/createrepo:latest)"
						if [ -z "$PUBLISHER_ID" ]; then
							# All good...
							break
						elif [ "$PUBLISHER_ID" = "$OLD_PUBLISHER_ID" ]; then
							printf '%s\n' "Publisher ${PUBLISHER_ID} refused to die. Aborting."
							exit 1
						else
							printf '%s\n' "--> Switching from waiting for publisher ${OLD_PUBLISHER_ID} to waiting for ${PUBLISHER_ID}"
							OLD_PUBLISHER_ID="$PUBLISHER_ID"
							retry=0
						fi
					fi
				done
			fi

			retry=0
			while [ "$retry" -lt "$MAX_RETRIES" ]; do
				printf '%s\n' "--> Running metadata generator"
				rm -rf "${path}"/.repodata
				/usr/bin/docker run --rm -e build_for_platform=$build_for_platform -v /home/abf/abf-downloads:/share/platforms rosalab/createrepo "${path}"
				rc=$?
				if [ "$rc" = "0" ]; then
					break
				else
					printf '%s\n' "---> Failed"
					retry=$((retry+1))
				fi
			done
		elif [[ "$save_to_platform" =~ ^.*rosa20* ]]; then
			printf '%s\n' "/usr/bin/genhdlist2 -v --nolock --allow-empty-media --versioned --xml-info --xml-info-filter='.lzma:lzma -0 --text' --no-hdlist --merge --no-bad-rpm ${path}"
			/usr/bin/genhdlist2 -v --nolock --allow-empty-media --versioned --xml-info --xml-info-filter='.lzma:lzma -0 --text' --no-hdlist --merge --no-bad-rpm ${path}
			rc=$?
		elif [[ "$save_to_platform" =~ ^.*rosa-virtualization.* ]]; then
			printf '%s\n' "/usr/bin/genhdlist2 -v --nolock --allow-empty-media --versioned --xml-info --xml-info-filter='.lzma:lzma -0 --text' --no-hdlist --merge --no-bad-rpm ${path}"
			/usr/bin/docker run --rm -e build_for_platform=$build_for_platform -v /home/abf/abf-downloads:/share/platforms rosalab/createrepo "${path}"
			rc=$?
		else
			printf '%s\n' "/usr/bin/genhdlist2 -v --nolock --allow-empty-media --versioned --xml-info --xml-info-filter='.lzma:lzma -0 --text' --no-hdlist --merge --no-bad-rpm ${path}"
			XZ_OPT="-7 -T0" /usr/bin/genhdlist2 -v --nolock --allow-empty-media --versioned --xml-info --xml-info-filter='.lzma:lzma -0 --text' --no-hdlist --merge --no-bad-rpm ${path}
			rc=$?
		fi
		rm -f "${path}"/media_info/{new,old}-metadata.lst
	else
		if [[ "$save_to_platform" =~ ^.*rosa-server.* ]]; then
			/usr/bin/docker run --rm -e build_for_platform=$build_for_platform -v /home/abf/abf-downloads:/share/platforms rosalab/createrepo "${path}" regenerate
			rc=$?
		elif [[ "$save_to_platform" =~ ^.*rosa-virtualization.* ]]; then
			/usr/bin/docker run --rm -e build_for_platform=$build_for_platform -v /home/abf/abf-downloads:/share/platforms rosalab/createrepo "${path}" regenerate
			rc=$?
		else
			printf '%s\n' "/usr/bin/genhdlist2 -v --clean --nolock --allow-empty-media --versioned --xml-info --xml-info-filter='.lzma:lzma -0 --text' --no-hdlist $path"
			/usr/bin/genhdlist2 -v --clean --nolock --allow-empty-media --versioned --xml-info --xml-info-filter='.lzma:lzma -0 --text' --no-hdlist ${path}
			rc=$?
		fi
	fi

	printf '%s\n' "${rc}" > "${container_path}"/"${arch}".exit-code
	printf '%s\n' "--> [$(LANG=en_US.UTF-8 date -u)] Done."
	cd -
}

if [[ "$save_to_platform" =~ ^.*rosa20.* ]]; then
	arches="SRPMS i586 x86_64"
else
	arches="SRPMS i686 x86_64"
fi

printf '%s\n' "--> Publishing for arches ${arches}"

# Checks that 'repository' directory exist
# FIXME media_info etc. probably shouldn't exist for dnf based trees
for arch in ${arches}; do
	mkdir -p "${repository_path}"/${arch}/"${rep_name}"/"${status}"/media_info
	if [ "$use_debug_repo" = 'true' ]; then
		mkdir -p "${repository_path}"/${arch}/debug_"${rep_name}"/"${status}"/media_info
	fi
done

# Checks sync status of repository
rep_locked=0
for arch in $arches ; do
	main_folder="${repository_path}"/"${arch}"/"${rep_name}"
	if [ -f "$main_folder/.repo.lock" ]; then
		rep_locked=1
		break
	else
		touch "${main_folder}"/.publish.lock
	fi
done

# Fails publishing if mirror is currently synchronising the repository state
if [ "${rep_locked}" != 0 ]; then
	# Unlocks repository for sync
	for arch in $arches ; do
		rm -f "${repository_path}"/"${arch}"/"${rep_name}"/.publish.lock
	done
	printf '%s\n' "--> ["$(LANG=en_US.UTF-8 date -u)"] ERROR: Mirror is currently synchronising the repository state."
	exit 1
fi

# Ensures that all packages exist
file_store_url="{$file_store_base}"/api/v1/file_stores.json
all_packages_exist=0
for arch in $arches ; do
	new_packages="${container_path}"/new."${arch}".list
	if [ -f "$new_packages" ]; then
		for sha1 in $(cat "${new_packages}"); do
			r="$(curl ${file_store_url}?hash=${sha1})"
			if [ "$r" = '[]' ]; then
				printf '%s\n' "--> Package with sha1 '$sha1' for $arch does not exist!!!"
				all_packages_exist=1
			fi
		done
	fi
done

# Fails publishing if some packages does not exist
if [ "${all_packages_exist}" != 0 ]; then
	# Unlocks repository for sync
	for arch in $arches ; do
		rm -f "${repository_path}"/"${arch}"/"${rep_name}"/.publish.lock
	done
	printf '%s\n' "--> [$(LANG=en_US.UTF-8 date -u)] ERROR: some packages does not exist"
	exit 1
fi

file_store_url="${file_store_base}"/api/v1/file_stores
for arch in $arches; do
	update_repo=0
	main_folder="$repository_path"/"$arch"/"$rep_name"
	rpm_backup="$main_folder"/"$status"-rpm-backup
	rpm_new="$main_folder"/"$status"-rpm-new
	m_info_backup="$main_folder"/"$status"-media_info-backup
	rm -rf "$rpm_backup" "$rpm_new" "$m_info_backup"
	mkdir -p "$rpm_backup"
	mkdir -p "$rpm_new"
	cp -rf $main_folder/$status/media_info "$m_info_backup"

	if [ "$use_debug_repo" = 'true' ]; then
		debug_main_folder=$repository_path/$arch/debug_$rep_name
		debug_rpm_backup="$debug_main_folder/$status-rpm-backup"
		debug_rpm_new="$debug_main_folder/$status-rpm-new"
		debug_m_info_backup="$debug_main_folder/$status-media_info-backup"
		rm -rf "$debug_rpm_backup" "$debug_rpm_new" "$debug_m_info_backup"
		mkdir -p "$debug_rpm_backup"
		mkdir -p "$debug_rpm_new"
		cp -rf "$debug_main_folder"/"$status"/media_info "$debug_m_info_backup"
	fi

	# Downloads new packages
	printf '%s\n' "--> [$(LANG=en_US.UTF-8 date -u)] Downloading new packages..."
	new_packages="$container_path/new.$arch.list"
	if [ -f "$new_packages" ]; then
		cd $rpm_new
		for sha1 in $(cat $new_packages) ; do
			fullname="$(sha1=$sha1 /bin/sh $script_path/extract_filename.sh)"
			if [ "$fullname" != '' ]; then
				curl -O -L "${file_store_url}"/"${sha1}"
				mv "$sha1" "$fullname"
				printf '%s\n' $fullname >> "$new_packages.downloaded"
				printf 'MIME type of $fullname: %s\n' $(file -bi $fullname)
				chown root:root $fullname
				# Add signature to RPM
				if [ "$sign_rpm" != '0' ]; then
					chmod 0666 "$fullname"
					printf '%s\n' "--> Starting to add sign to rpm package."
					rpm --addsign "$fullname"
					# Save exit code
					rc=$?
					if [ "${rc}" = '0' ]; then
						printf '%s\n' "--> Package $fullname has been signed successfully."
					else
						printf '%s\n' "--> Package $fullname has not been signed successfully!!!"
					fi
				else
					printf '%s\n' "--> RPM signing is disabled"
				fi
				chmod 0644 "$fullname"
			else
				printf '%s\n' "--> Package with sha1 '$sha1' does not exist!!!"
			fi
		done
		update_repo=1
	fi
	printf '%s\n' "--> [$(LANG=en_US.UTF-8 date -u)] Done."

	# Creates backup
	printf '%s\n' "--> [$(LANG=en_US.UTF-8 date -u)] Creating backup..."
	old_packages="$container_path/old.$arch.list"
	if [ -f "$old_packages" ]; then
		for fullname in $(cat $old_packages) ; do
			package=$main_folder/$status/$fullname
			if [ -f "$package" ]; then
				printf '%s\n' "mv $package $rpm_backup/"
				mv $package $rpm_backup/
			fi

			if [ "$use_debug_repo" = 'true' ]; then
				debug_package=$debug_main_folder/$status/$fullname
				if [ -f "$debug_package" ]; then
					printf '%s\n' "mv $debug_package $debug_rpm_backup/"
					mv $debug_package $debug_rpm_backup/
				fi
			fi
		done
		update_repo=1
	fi
	printf '%s\n' "--> [$(LANG=en_US.UTF-8 date -u)] Done."
	printf '%s\n' "--> [$(LANG=en_US.UTF-8 date -u)] Starting to move packages to the target repository."

	# some debug output
	if [ "$debug_output" = "1" ]; then
		printf '%s\n' "$main_folder"
		ls -l $main_folder/release
		ls -l $main_folder/updates
		printf '%s\n' $debug_main_folder
		printf '%s\n' $rpm_new
	fi

	# Move packages into repository
	if [ -f "$new_packages" ]; then
		if [ "$use_debug_repo" = 'true' ]; then
			for file in $( ls -1 $rpm_new/ | grep .rpm$ ) ; do
				rpm_name=$(rpm -qp --queryformat %{NAME} $rpm_new/$file)
				if [[ "$rpm_name" =~ debuginfo ]]; then
					mv $rpm_new/$file $debug_main_folder/$status/
				else
					mv $rpm_new/$file $main_folder/$status/
				fi
			done
		else
			mv $rpm_new/* $main_folder/$status/
		fi
	fi

	printf '%s\n' "--> [$(LANG=en_US.UTF-8 date -u)] Done."
	cd "${main_folder}"
	rm -rf "${rpm_new}"

	if [ $update_repo != 1 ]; then
		if [ "$is_container" = 'true' ]; then
			rm -rf "$repository_path"/"$arch"
		fi
		if [ "$regenerate_metadata" != 'true' ]; then
			continue
		fi
	fi

	printf '%s\n' "build_repo "${main_folder}/${status}" "${arch}" "${regenerate_metadata}""
	build_repo "$main_folder/$status" "$arch" "$regenerate_metadata" "$sign_rpm" "$KEYNAME" &
	if [ "$use_debug_repo" = 'true' ]; then
		build_repo "${debug_main_folder}/${status}" "${arch}" "${regenerate_metadata}" &
	fi

	if [ "${regenerate_metadata}" = 'true' ] && [ -d "${main_folder}/testing" ]; then
		# 0 - disable resign of packages
		build_repo "${main_folder}/testing" "${arch}" "${regenerate_metadata}" &
	fi
done #arches

# Waiting for createrepo...
wait

rc=0
# Check exit codes
for arch in $arches ; do
	path="$container_path/$arch.exit-code"
	if [ -f "$path" ]; then
		rc=$(cat $path)
		if [ "${rc}" != 0 ]; then
			rpm -qa | grep createrepo_c
			break
		fi
	fi
done

# Check exit code after build and rollback
if [ "${rc}" != 0 ]; then
	cd $script_path/
	TESTING=$testing RELEASED=$released REPOSITORY_NAME=$rep_name USE_FILE_STORE=false /bin/bash "$script_path"/rollback.sh
else
	for arch in $arches ; do
		main_folder=$repository_path/$arch/$rep_name
		rpm_backup="$main_folder/$status-rpm-backup"
		rpm_new="$main_folder/$status-rpm-new"
		m_info_backup="$main_folder/$status-media_info-backup"
		rm -rf "$rpm_backup" "$rpm_new" "$m_info_backup"

		if [ "$use_debug_repo" = 'true' ]; then
			debug_main_folder=$repository_path/$arch/debug_$rep_name
			debug_rpm_backup="$debug_main_folder/$status-rpm-backup"
			debug_rpm_new="$debug_main_folder/$status-rpm-new"
			debug_m_info_backup="$debug_main_folder/$status-media_info-backup"
			rm -rf "$debug_rpm_backup" "$debug_rpm_new" "$debug_m_info_backup"
		fi

		# Unlocks repository for sync
		rm -f "${main_folder}"/.publish.lock
		[ -e "${path}"/.repodata ] && rm -rf "${path}"/.repodata
	done
fi

exit "${rc}"
