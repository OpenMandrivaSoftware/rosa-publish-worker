#!/bin/sh

echo '--> Resing RPM script'

unset SOURCED || :
for i in "${HOME}/rosa-publish-worker/scripts/mdv" "."
do
	if [ -f "${i}/common-funcs.sh" ]; then
		. "${i}/common-funcs.sh" && \
		SOURCED=1 && \
		break
	fi
done
if [ "$SOURCED" != 1 ]; then
	printf 'File common-funcs.sh not found and not sourced!\n'
	exit 1
fi
unset SOURCED

released="$RELEASED"
rep_name="$REPOSITORY_NAME"
repository_path="${PLATFORM_PATH}"

gnupg_path=/root/gnupg

if [ ! -d "$gnupg_path" ]; then
  echo "--> $gnupg_path does not exist"
  exit 0
fi

function resign_all_rpm_in_folder {
  folder=$1
  if [ -d "$folder" ]; then
    for file in $( ls -1 $folder/ | grep .rpm$ ) ; do
      chmod 0666 $folder/$file
      rpm --addsign $folder/$file
      chmod 0644 $folder/$file
    done
  fi
}

_local_gpg_setup

for arch in SRPMS i586 x86_64; do
  for rep in release updates ; do
    resign_all_rpm_in_folder "$repository_path/$arch/$rep_name/$rep" &
    resign_all_rpm_in_folder "$repository_path/$arch/debug_$rep_name/$rep" &
  done
done

# Waiting for resign_all_rpm_in_folder...
wait

exit 0
