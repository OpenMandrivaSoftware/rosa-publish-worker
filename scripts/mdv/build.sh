#!/bin/sh

echo '--> mdv-scripts/publish-packages: build.sh'

# set script debug
debug_output=0

# Update genhdlist2
sudo urpmi.update -a
sudo urpmi --auto --downloader wget --wget-options --auth-no-challenge --no-suggests --no-verify-rpm --fastunsafe --auto genhdlist2 perl-URPM rootcerts

released="$RELEASED"
rep_name="$REPOSITORY_NAME"
is_container="$IS_CONTAINER"
testing="$TESTING"
id="$ID"
# save_to_platform - main or personal platform
save_to_platform="$SAVE_TO_PLATFORM"
# build_for_platform - only main platform
build_for_platform="$BUILD_FOR_PLATFORM"
regenerate_metadata="$REGENERATE_METADATA"
key_server="pool.sks-keyservers.net"
OMV_key="BF81DE15"

echo "TESTING = $testing"
echo "RELEASED = $released"
echo "REPOSITORY_NAME = $rep_name"

# Current path:
# - /home/vagrant/scripts/publish-packages
script_path=`pwd`

# Container path:
# - /home/vagrant/container
container_path=/home/vagrant/container

# /home/vagrant/share_folder contains:
# - http://abf.rosalinux.ru/downloads/rosa2012.1/repository
# - http://abf.rosalinux.ru/downloads/akirilenko_personal/repository/rosa2012.1
platform_path=/home/vagrant/share_folder

repository_path=$platform_path

# See: https://abf.rosalinux.ru/abf/abf-ideas/issues/51
# Move debug packages to special separate repository
# override below if need
use_debug_repo='true'

# Checks 'released' status of platform
status='release'
if [ "$released" == 'true' ] ; then
  status='updates'
fi
if [ "$testing" == 'true' ] ; then
  status='testing'
  use_debug_repo='false'
fi

# Checks that 'repository' directory exist
mkdir -p $repository_path/{SRPMS,i586,x86_64,armv7l,armv7hl,aarch64}/$rep_name/$status/media_info
if [ "$use_debug_repo" == 'true' ] ; then
  mkdir -p $repository_path/{SRPMS,i586,x86_64,armv7l,armv7hl,aarch64}/debug_$rep_name/$status/media_info
fi

sign_rpm=0
gnupg_path=/home/vagrant/.gnupg
keyname=''
if [ "$testing" != 'true' ] ; then

  if [ ! -d "$gnupg_path" ]; then
    echo "--> $gnupg_path does not exist, signing rpms will be not possible"
  else
    echo "--> Checking platform"
# (tpg) disable rpm signing for cooker as it is broken
    if [[ "$save_to_platform" =~ ^.*cooker.*$ ]]; then
	sign_rpm=0
	echo "--> Rpm signing disabled on cooker by TPG"
    else
	sign_rpm=1
    fi
    /bin/bash $script_path/init_rpmmacros.sh

    if [[ "$save_to_platform" =~ ^.*openmandriva.*$ ]] || [[ "$save_to_platform" =~ ^.*cooker.*$ ]]; then
      echo "--> Importing OpenMandriva GPG key from external keyserver"
      GNUPGHOME="$gnupg_path" gpg --homedir $gnupg_path --keyserver $key_server --recv-keys $OMV_key
    # else
    #   echo "--> Missing gpg key for this platform"
    fi

    keyname=`GNUPGHOME="$gnupg_path" gpg --list-public-keys --homedir $gnupg_path |
      sed -n 3p |
      awk '{ print $2 }' |
      awk '{ sub(/.*\//, ""); print tolower($0) }'`

    echo "--> keyname: $keyname"

  fi
fi


function build_repo {
  path=$1
  arch=$2
  regenerate=$3
  start_sign_rpms=$4
  key_name=$5

  # resign all packages
  # Disable resign of packages at regeneration
  start_sign_rpms='0'
  if [ "$regenerate" == 'true' ]; then
    if [ "$start_sign_rpms" == '1' ] ; then
      echo "--> Starting to sign rpms in '$path'"
      # evil lo0pz
      # for i in `ls -1 $path/*.rpm`; do
      for i in `find $path -name '*.rpm'`; do

        has_key=`rpm -Kv $i | grep 'key ID' | grep "$key_name"`
        if [ "$has_key" == '' ] ; then
          chmod 0666 $i;
          rpm --resign $i;
          chmod 0644 $i;
        else
          echo "--> Package '$i' already signed"
        fi

      done
      # Save exit code
      rc=$?
      if [[ $rc == 0 ]] ; then
        echo "--> Packages in '$path' has been signed successfully."
      else
        echo "--> Packages in '$path' has not been signed successfully!!!"
      fi
    else
      echo "--> RPM signing is disabled"
    fi
  fi

  # Build repo
  echo "--> [`LANG=en_US.UTF-8  date -u`] Generating repository..."
  rpm -q perl-URPM
  cd $script_path/
  if [ "$regenerate" != 'true' ] ; then

    # genhdlist2 in rosa/omv supports "--merge" option that can be used to speed up publication process.
    # See: https://abf.io/abf/abf-ideas/issues/149
    rm -f ${path}/media_info/{new,old}-metadata.lst
    [[ -f ${container_path}/new.${arch}.list.downloaded ]] && cp -f ${container_path}/new.${arch}.list.downloaded ${path}/media_info/new-metadata.lst
    [[ -f ${container_path}/old.${arch}.list ]] && cp -f ${container_path}/old.${arch}.list ${path}/media_info/old-metadata.lst

    if [ "$debug_output" = "1" ]; then
	echo "---> ${path}/media_info/new-metadata.lst:"
	cat ${path}/media_info/new-metadata.lst
	echo '<--- end'
	echo "---> ${path}/media_info/old-metadata.lst:"
	cat ${path}/media_info/old-metadata.lst
	echo '<--- end'
    fi

    #/usr/bin/genhdlist2 -v --nolock --allow-empty-media --versioned --xml-info \
    #  --xml-info-filter='.lzma:lzma -0 --text' --no-hdlist "$path"
    if [[ "$save_to_platform" =~ ^.*cooker.*$ ]]; then
	echo "/usr/bin/genhdlist2 -v --nolock --allow-empty-media --versioned --synthesis-filter='.cz:xz -7 -T0' --xml-info --xml-info-filter='.lzma:xz -7 -T0' --no-hdlist --merge --no-bad-rpm ${path}"
	/usr/bin/genhdlist2 -v --nolock --allow-empty-media --versioned --synthesis-filter='.cz:xz -7 -T0' --xml-info --xml-info-filter='.lzma:xz -7 -T0' --no-hdlist --merge --no-bad-rpm ${path}
	rc=$?
    else
	echo "/usr/bin/genhdlist2 -v --nolock --allow-empty-media --versioned --xml-info --xml-info-filter='.lzma:lzma -0 --text' --no-hdlist --merge --no-bad-rpm ${path}"
	/usr/bin/genhdlist2 -v --nolock --allow-empty-media --versioned --xml-info --xml-info-filter='.lzma:lzma -0 --text' --no-hdlist --merge --no-bad-rpm ${path}
	rc=$?
    fi

    rm -f ${path}/media_info/{new,old}-metadata.lst
  else
    echo "/usr/bin/genhdlist2 -v --clean --nolock --allow-empty-media --versioned --xml-info --xml-info-filter='.lzma:lzma -0 --text' --no-hdlist $path"
    /usr/bin/genhdlist2 -v --clean --nolock --allow-empty-media --versioned --xml-info --xml-info-filter='.lzma:lzma -0 --text' --no-hdlist ${path}
    rc=$?
  fi
  # Save genhdlist2 exit code
  echo $rc > "$container_path/$arch.exit-code"
  echo "--> [`LANG=en_US.UTF-8  date -u`] Done."
}

rx=0
arches="SRPMS i586 x86_64 armv7l armv7hl aarch64"

# Checks sync status of repository
rep_locked=0
for arch in $arches ; do
  main_folder=$repository_path/$arch/$rep_name
  if [ -f "$main_folder/.repo.lock" ]; then
    rep_locked=1
    break
  else
    touch $main_folder/.publish.lock
  fi
done

# Fails publishing if mirror is currently synchronising the repository state
if [ $rep_locked != 0 ] ; then
  # Unlocks repository for sync
  for arch in $arches ; do
    rm -f $repository_path/$arch/$rep_name/.publish.lock
  done
  echo "--> [`LANG=en_US.UTF-8  date -u`] ERROR: Mirror is currently synchronising the repository state."
  exit 1
fi

# Ensures that all packages exist
file_store_url='http://file-store.rosalinux.ru/api/v1/file_stores.json'
all_packages_exist=0
for arch in $arches ; do
  new_packages="$container_path/new.$arch.list"
  if [ -f "$new_packages" ]; then
    for sha1 in `cat $new_packages` ; do
      r=`curl ${file_store_url}?hash=${sha1}`
      if [ "$r" == '[]' ] ; then
        echo "--> Package with sha1 '$sha1' for $arch does not exist!!!"
        all_packages_exist=1
      fi
    done
  fi
done
# Fails publishing if some packages does not exist
if [ $all_packages_exist != 0 ] ; then
  # Unlocks repository for sync
  for arch in $arches ; do
    rm -f $repository_path/$arch/$rep_name/.publish.lock
  done
  echo "--> [`LANG=en_US.UTF-8  date -u`] ERROR: some packages does not exist"
  exit 1
fi

file_store_url='http://file-store.rosalinux.ru/api/v1/file_stores'
for arch in $arches ; do
  update_repo=0
  main_folder=$repository_path/$arch/$rep_name
  rpm_backup="$main_folder/$status-rpm-backup"
  rpm_new="$main_folder/$status-rpm-new"
  m_info_backup="$main_folder/$status-media_info-backup"
  rm -rf $rpm_backup $rpm_new $m_info_backup
  mkdir {$rpm_backup,$rpm_new}
  cp -rf $main_folder/$status/media_info $m_info_backup

  if [ "$use_debug_repo" == 'true' ] ; then
    debug_main_folder=$repository_path/$arch/debug_$rep_name
    debug_rpm_backup="$debug_main_folder/$status-rpm-backup"
    debug_rpm_new="$debug_main_folder/$status-rpm-new"
    debug_m_info_backup="$debug_main_folder/$status-media_info-backup"
    rm -rf $debug_rpm_backup $debug_rpm_new $debug_m_info_backup
    mkdir {$debug_rpm_backup,$debug_rpm_new}
    cp -rf $debug_main_folder/$status/media_info $debug_m_info_backup
  fi

  # Downloads new packages
  echo "--> [`LANG=en_US.UTF-8  date -u`] Downloading new packages..."
  new_packages="$container_path/new.$arch.list"
  if [ -f "$new_packages" ]; then
    cd $rpm_new
    for sha1 in `cat $new_packages` ; do
      fullname=`sha1=$sha1 /bin/bash $script_path/extract_filename.sh`
      if [ "$fullname" != '' ] ; then
        curl -O -L "$file_store_url/$sha1"
        mv $sha1 $fullname
        echo $fullname >> "$new_packages.downloaded"
        chown root:root $fullname
        # Add signature to RPM
        if [ $sign_rpm != 0 ] ; then
          chmod 0666 $fullname
          echo "--> Starting to sign rpm package"
          rpm --addsign $fullname
          # Save exit code
          rc=$?
          if [[ $rc == 0 ]] ; then
            echo "--> Package '$fullname' has been signed successfully."
          else
            echo "--> Package '$fullname' has not been signed successfully!!!"
          fi
        else
          echo "--> RPM signing is disabled"
        fi
        chmod 0644 $fullname
      else
        echo "--> Package with sha1 '$sha1' does not exist!!!"
      fi
    done
    update_repo=1
  fi
  echo "--> [`LANG=en_US.UTF-8  date -u`] Done."

  # Creates backup
  echo "--> [`LANG=en_US.UTF-8  date -u`] Creating backup..."
  old_packages="$container_path/old.$arch.list"
  if [ -f "$old_packages" ]; then
    for fullname in `cat $old_packages` ; do
      package=$main_folder/$status/$fullname
      if [ -f "$package" ]; then
        echo "mv $package $rpm_backup/"
        mv $package $rpm_backup/
      fi

      if [ "$use_debug_repo" == 'true' ] ; then
        debug_package=$debug_main_folder/$status/$fullname
        if [ -f "$debug_package" ]; then
          echo "mv $debug_package $debug_rpm_backup/"
          mv $debug_package $debug_rpm_backup/
        fi
      fi

    done
    update_repo=1
  fi
  echo "--> [`LANG=en_US.UTF-8  date -u`] Done."

  echo "--> [`LANG=en_US.UTF-8  date -u`] Starting to move packages to the target repository."
    #some debug output
    if [ "$debug_output" = "1" ]; then
	echo $main_folder
	ls -l $main_folder/release
	ls -l $main_folder/updates
	echo $debug_main_folder
	echo $rpm_new
    fi
  # Move packages into repository
  if [ -f "$new_packages" ]; then
    if [ "$use_debug_repo" == 'true' ] ; then
      for file in $( ls -1 $rpm_new/ | grep .rpm$ ) ; do
        rpm_name=`rpm -qp --queryformat %{NAME} $rpm_new/$file`
        if [[ "$rpm_name" =~ debuginfo ]] ; then
          mv $rpm_new/$file $debug_main_folder/$status/
        else
          mv $rpm_new/$file $main_folder/$status/
        fi
      done
    else
      mv $rpm_new/* $main_folder/$status/
    fi
  fi
  echo "--> [`LANG=en_US.UTF-8  date -u`] Done."
  cd $main_folder
  rm -rf $rpm_new

  if [ $update_repo != 1 ] ; then
    if [ "$is_container" == 'true' ] ; then
      rm -rf $repository_path/$arch
    fi
    if [ "$regenerate_metadata" != 'true' ] ; then
      continue
    fi
  fi

  echo "build_repo "$main_folder/$status" "$arch" "$regenerate_metadata" "$sign_rpm" "$keyname""
  build_repo "$main_folder/$status" "$arch" "$regenerate_metadata" "$sign_rpm" "$keyname" &
  if [ "$use_debug_repo" == 'true' ] ; then
    build_repo "$debug_main_folder/$status" "$arch" "$regenerate_metadata" "$sign_rpm" "$keyname" &
  fi

  if [ "$regenerate_metadata" == 'true' ] && [ -d "$main_folder/testing" ] ; then
    # 0 - disable resign of packages
    build_repo "$main_folder/testing" "$arch" "$regenerate_metadata" "0" "$keyname" &
  fi

done

# Waiting for genhdlist2...
wait

rc=0
# Check exit codes
for arch in $arches ; do
  path="$container_path/$arch.exit-code"
  if [ -f "$path" ] ; then
    rc=`cat $path`
    if [ $rc != 0 ] ; then
      rpm -qa | grep genhdlist2
      break
    fi
  fi
done


# Check exit code after build and rollback
if [ $rc != 0 ] ; then
  cd $script_path/
  TESTING=$testing RELEASED=$released REPOSITORY_NAME=$rep_name USE_FILE_STORE=false /bin/bash $script_path/rollback.sh
else
  for arch in $arches ; do
    main_folder=$repository_path/$arch/$rep_name
    rpm_backup="$main_folder/$status-rpm-backup"
    rpm_new="$main_folder/$status-rpm-new"
    m_info_backup="$main_folder/$status-media_info-backup"
    rm -rf $rpm_backup $rpm_new $m_info_backup

    if [ "$use_debug_repo" == 'true' ] ; then
      debug_main_folder=$repository_path/$arch/debug_$rep_name
      debug_rpm_backup="$debug_main_folder/$status-rpm-backup"
      debug_rpm_new="$debug_main_folder/$status-rpm-new"
      debug_m_info_backup="$debug_main_folder/$status-media_info-backup"
      rm -rf $debug_rpm_backup $debug_rpm_new $debug_m_info_backup
    fi

    # Unlocks repository for sync
    rm -f $main_folder/.publish.lock
  done
fi

exit $rc
