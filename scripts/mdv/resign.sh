#!/bin/sh

echo '--> Resing RPM script'
released="$RELEASED"
rep_name="$REPOSITORY_NAME"
repository_path="${PLATFORM_PATH}"

gnupg_path=/root/gnupg

if [ ! -d "$gnupg_path" ]; then
  echo "--> $gnupg_path does not exist"
  exit 0
fi

function make_macro {
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
}
make_macro

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

for arch in SRPMS i586 x86_64; do
  for rep in release updates ; do
    resign_all_rpm_in_folder "$repository_path/$arch/$rep_name/$rep" &
    resign_all_rpm_in_folder "$repository_path/$arch/debug_$rep_name/$rep" &
  done
done

# Waiting for resign_all_rpm_in_folder...
wait

exit 0
