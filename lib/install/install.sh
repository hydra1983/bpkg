#!/bin/bash

if ! type -f bpkg-logging &>/dev/null; then
  echo "error: bpkg-logging not found, aborting"
  exit 1
else
  source $(which bpkg-logging)
fi

if ! type -f bpkg-utils &>/dev/null; then
  echo "error: bpkg-utils not found, aborting"
  exit 1
else
  source $(which bpkg-utils)
fi

if ! type -f bpkg-utils-url &>/dev/null; then
  echo "error: bpkg-utils-url not found, aborting"
  exit 1
else
  source $(which bpkg-utils-url)
fi

bpkg_initrc

_wrap_script () {
  local src dest src_content src_shabang tmp_script_file dest_name break_mode pkg_prefix

  src="$1"
  dest="$2"
  break_mode="$3"
  src_content=$(cat ${src})
  dest_name=$(basename ${dest})

  if [[ "$(cat ${src} | head -n 1 | grep '#!')" ]]; then
    src_shabang=$(cat ${src} | head -n 1)
    src_content=$(cat ${src} | tail -n +2)
  else
    src_shabang="#!/usr/local/bin/bash"
  fi

  if (( 1 == break_mode )); then
    pkg_prefix="${BPKG_PKG_PREFIX}/share"
  else
    pkg_prefix="${BPKG_PKG_PREFIX}"
  fi

  readonly tmp_script_file=$(mktemp "/tmp/bpkg.wrapper.XXXXXXXXXX")
  echo "${src_shabang}" | tee -a "${tmp_script_file}" > /dev/null

  cat <<EOF | tee -a "${tmp_script_file}" > /dev/null

#########################################
# THIS SECTION !!SHOULD NOT!! BE MODIFIED BY
# DEVELOPERS AS IT PROVIDES COMMON FUNCTIONS
# FOR ALL KINDS OF SCRIPTS
#
# Maintainer: Edison Guo <hydra1983@gmail.com>
#########################################

# Load bpkg-logging
if ! type -f bpkg-logging &>/dev/null; then
  echo "error: bpkg-logging not found, aborting"
  exit 1
else
  source \$(which bpkg-logging)
fi

# Load package
function __load () {
  local package_file script_file script_dir script_name

  script_file="\$1"
  package_file="\$2"

  if [[ -L \${script_file} ]] ; then
      script_dir=\$(cd \$(dirname \$(readlink -f \${script_file})); pwd)
  else
      script_dir=\$(cd \$(dirname \${script_file}); pwd)
  fi

  script_name="\$(basename \${script_file})"

  if [[ -d "\${script_dir}/../share/\${script_name}" ]]; then
      script_dir="\$(cd "\${script_dir}/../share/\${script_name}"; pwd)"
  fi

  if [[ -s "\${script_dir}/\${package_file}" ]]; then
    source "\${script_dir}/\${package_file}"
  elif [[ -s "\${script_dir}/${pkg_prefix}/\${package_file}/\${package_file}" ]]; then
    source "\${script_dir}/${pkg_prefix}/\${package_file}/\${package_file}"
  else
    bpkg_warn "Cannot load invalid file '\${script_dir}/${pkg_prefix}/\${package_file}/\${package_file}' as it's missing or empty"
  fi
}
#########################################
EOF

  echo "${src_content}" | tee -a "${tmp_script_file}" > /dev/null

  cp -f "${tmp_script_file}" "${dest}"
  chmod +x "${dest}"

  rm -f "${tmp_script_file}"
}

## try to install a package from a specific remote
## returns values:
##   0: success
##   1: the package was not found on the remote
##   2: a fatal error occurred
_bpkg_install_from_remote () {
  local pkg="$1"
  local remote="$2"
  local git_remote="$3"
  local needs_global=$4
  local break_mode=$5
  local needs_deps=$6
  local auth_info="$7"

  local cwd=$(pwd)
  local url=''
  local uri=''
  local version=''
  local status=''
  local json=''
  local user=''
  local name=''
  local version=''
  local auth_param=''
  local has_pkg_json=1
  declare -a local pkg_parts=()
  declare -a local remote_parts=()
  declare -a local scripts=()
  declare -a local files=()
  local package_json_url makefile_url
  local install_basedir install_bindir install_sharedir

  ## get version if available
  pkg_parts=(${pkg/@/ })
  bpkg_debug "pkg_parts" "${pkg_parts[@]}"

  if [[ ${#pkg_parts[@]} -eq 1 ]]; then
    version='master'
    #bpkg_info "Using latest (master)"
  elif [[ ${#pkg_parts[@]} -eq 2 ]]; then
    name="${pkg_parts[0]}"
    version="${pkg_parts[1]}"
  else
     bpkg_error 'Error parsing package version'
    return 1
  fi

  ## split by user name and repo
  pkg_parts=(${pkg//\// })
  bpkg_debug "pkg_parts" "${pkg_parts[@]}"

  if [[ ${#pkg_parts[@]} -eq 0 ]]; then
    bpkg_error 'Unable to determine package name'
    return 1
  elif [[ ${#pkg_parts[@]} -eq 1 ]]; then
    user="${BPKG_USER}"
    name="${pkg_parts[0]}"
  else
    name="${pkg_parts[${#pkg_parts[@]}-1]}"
    unset pkg_parts[${#pkg_parts[@]}-1]
    pkg_parts=( "${pkg_parts[@]}" )
    user="$(IFS='/' ; echo "${pkg_parts[*]}")"
  fi

  ## clean up name of weird trailing
  ## versions and slashes
  name=${name/@*//}
  name=${name////}

  bpkg_debug "user" "${user}"
  bpkg_debug "name" "${name}"

  ## Adapter to different kind of git hosting services
  if bpkg_is_coding_net "${remote}"; then
    uri="/u/${user}/p/${name}/git/raw/${version}"
  elif bpkg_is_github_raw "${remote}"; then
    uri="/${user}/${name}/${version}"
  elif bpkg_is_local_path "${remote}"; then
    uri="/${user}/${name}"
  else
    uri="/${user}/${name}/raw/${version}"
  fi

  ## check to see if remote is raw with oauth (GHE) or access token
  if [[ ! -z "${auth_info}" ]]; then
    OLDIFS="${IFS}"
    IFS="'|'"
    local auth_info_parts=($auth_info)
    IFS="${OLDIFS}"
    local token=${auth_info_parts[1]}

    if [[ "${auth_info:0:10}" == "raw-oauth|" ]]; then
      bpkg_info 'Using OAUTH basic with content requests'
      auth_param="-u \"$token:x-oauth-basic\""

      ## If git remote is a URL, and doesn't contain token information, we
      ## inject it into the <user>@host field
      if [[ "$git_remote" == https://* ]] && [[ "$git_remote" != *x-oauth-basic* ]] && [[ "$git_remote" != *${token}* ]]; then
        git_remote="${git_remote/https:\/\//https:\/\/$token:x-oauth-basic@}"
      fi
    elif [[ "${auth_info:0:11}" == "raw-access|" ]]; then
      auth_param="--header 'PRIVATE-TOKEN: $token'"
    fi
  fi

  ## clean up extra slashes in uri
  uri=${uri/\/\///}
  bpkg_info "Install $uri from remote $remote [$git_remote]"

  ## Ensure remote is reachable
  ## If a remote is totally down, this will be considered a fatal
  ## error since the user may have intended to install the package
  ## from the broken remote.
  {
    if ! bpkg_url_exists "${remote}" "${auth_param}"; then
      bpkg_error "Remote unreachable: ${remote}"
      return 2
    fi
  }

  ## build url
  url="${remote}${uri}"

  if bpkg_is_coding_net "${remote}"; then
    repo_url="${git_remote}/u/${user}/p/${name}/git"
  elif bpkg_is_local_path "${remote}"; then
    repo_url="${git_remote}/${user}/${name}"
  else
    repo_url="${git_remote}/${user}/${name}.git"
  fi

  ## determine if 'package.json' exists at url
  package_json_url="${url}/package.json?$(date +%s)"
  makefile_url="${url}/Makefile?$(date +%s)"

  if bpkg_is_local_path "${url}"; then
    package_json_url="${url}/package.json"
    makefile_url="${url}/Makefile"
  fi

  {
    if ! bpkg_url_exists "${package_json_url}" "${auth_param}"; then
      bpkg_warn 'package.json doesn`t exist'
      has_pkg_json=0
      # check to see if there's a Makefile. If not, this is not a valid package
      if ! bpkg_url_exists "${makefile_url}" "${auth_param}"; then
        local makefile_missing_msg
        makefile_missing_msg="Makefile not found, skipping remote: $url"
        if (( 0 == break_mode )); then
          bpkg_error "${makefile_missing_msg}"
          return 1
        else
          bpkg_warn "${makefile_missing_msg}"
        fi
      fi
    fi
  }

  ## read package.json
  json=$(bpkg_read_package_json "${package_json_url}" "${auth_param}")

  if (( 1 == has_pkg_json )); then
    ## get package name from 'package.json'
    name="$(
      echo -n "${json}" |
      bpkg-json -b |
      grep 'name' |
      awk '{ $1=""; print $0 }' |
      tr -d '\"' |
      tr -d ' '
    )"

    ## check if forced global
    if [[ ! -z "$(echo -n "${json}" | bpkg-json -b | grep '\["global"\]' | awk '{ print $2 }' | tr -d '"')" ]]; then
      needs_global=1
    fi

    ## construct scripts array
    {
      scripts=$(echo -n "${json}" | bpkg-json -b | grep '\["scripts' | awk '{$1=""; print $0 }' | tr -d '"')
      OLDIFS="${IFS}"

      ## multilines to array
      new_scripts=()
      while read -r script; do
        new_scripts+=("${script}")
      done <<< "${scripts}"

      ## account for existing space
      scripts=("${new_scripts[@]}")
    }

    ## construct files array
    {
      files=$(echo -n "${json}" | bpkg-json -b | grep '\["files' | awk '{$1=""; print $0 }' | tr -d '"')
      OLDIFS="${IFS}"

      ## multilines to array
      new_files=()
      while read -r file; do
        new_files+=("${file}")
      done <<< "${files}"

      ## account for existing space
      files=("${new_files[@]}")
    }

  fi

  if (( 1 == needs_global )); then
    bpkg_info "Install ${url} globally"
  fi

  if (( 1 == break_mode )); then
    bpkg_warn "Install ${url} in break mode"
  fi

  ## build global in legacy mode if needed
  if (( 1 == needs_global )) && (( 0 == break_mode )); then
    if (( 1 == has_pkg_json )); then
      ## install bin if needed
      build="$(echo -n "${json}" | bpkg-json -b | grep '\["install"\]' | awk '{$1=""; print $0 }' | tr -d '\"')"
      build="$(echo -n "${build}" | sed -e 's/^ *//' -e 's/ *$//')"
    fi

    if [[ -z "${build}" ]]; then
      bpkg_warn "Missing build script"
      bpkg_warn "Trying \`make install\`..."
      build="make install"
    fi

    { (
      ## go to tmp dir
      cd "$( [[ ! -z "${TMPDIR}" ]] && echo "${TMPDIR}" || echo /tmp)" &&
      ## prune existing
      rm -rf "${name}-${version}" &&
      ## shallow clone
      bpkg_info "Cloning ${repo_url} to ${name}-${version}" &&
      git clone "${repo_url}" "${name}-${version}" &&
      (
        ## move into directory
        cd "${name}-${version}" &&
        git checkout ${version} &&
        ## wrap
        for script in $scripts; do (
            local script="$(echo $script | xargs basename )"

            if [[ "${script}" ]]; then
              cp -f "$(pwd)/${script}" "$(pwd)/${script}.orig"
              _wrap_script "$(pwd)/${script}.orig" "$(pwd)/${script}" "${break_mode}"
            fi
        ) done &&
        ## build
        bpkg_info "Performing install: \`${build}'" &&
        eval "${build}"
      ) &&
      ## clean up
      rm -rf "${name}-${version}"
    ) }
  fi

  if (( 1 == needs_global )) && (( 1 == break_mode )); then
    install_basedir="/usr/local"
    install_bindir="${install_basedir}/bin"
    install_sharedir="${install_basedir}/share/${name}"
  elif (( 0 == needs_global )) && (( 0 == break_mode )); then
    install_basedir="${cwd}/${BPKG_PKG_PREFIX}"
    install_bindir="${install_basedir}/bin"
    install_sharedir="${install_basedir}/${name}"
  elif (( 0 == needs_global )) && (( 1 == break_mode )); then
    install_basedir="${cwd}/${BPKG_PKG_PREFIX}"
    install_bindir="${install_basedir}/bin"
    install_sharedir="${install_basedir}/share/${name}"
  fi

  ## perform local install otherwise
  if (( 0 == needs_global )) || (( 1 == break_mode )); then
    ## copy package.json over
    bpkg_save_remote_file "${url}/package.json" "${install_sharedir}/package.json" "${auth_param}"

    ## make '${BPKG_PKG_PREFIX}/bin' directory if possible
    mkdir -p "${install_bindir}"

    ## make '${BPKG_PKG_PREFIX}/share' directory if possible
    mkdir -p "${install_sharedir}"

    # install package dependencies
    if (( 1 == needs_deps )); then
      if (( 1 == break_mode )); then
        (cd "${install_sharedir}" && bpkg getdeps -b)
      else
        (cd "${install_sharedir}" && bpkg getdeps)
      fi
    fi

    if [[ "${#scripts[@]}" -gt '0' ]]; then
      ## grab each script and place in ${BPKG_PKG_PREFIX} directory
      bpkg_debug "install_scripts" "Install scripts '${scripts[*]}'"

      for (( i = 0; i < ${#scripts[@]} ; ++i )); do
        (
          local script="${scripts[$i]}"
          script="$(basename "${script}")"

          if [[ "${script}" ]]; then
            bpkg_save_remote_file "${url}/${script}" "${install_sharedir}/${script}" "${auth_param}"
            local scriptname="${script%.*}"
            bpkg_debug "${scriptname} to PATH" "${install_bindir}/${scriptname}"
            cp -f "${install_sharedir}/${script}" "${install_sharedir}/${script}.orig"
            _wrap_script "${install_sharedir}/${script}.orig" "${install_sharedir}/${script}" "${break_mode}"
            ln -sf "${install_sharedir}/${script}" "${install_bindir}/${scriptname}"
            chmod u+x "${install_bindir}/${scriptname}"
          fi
        )
      done
    else
      bpkg_warn "instal_scripts" "No scripts to be installed"
    fi

    if [[ "${#files[@]}" -gt '0' ]]; then
      ## grab each file
      for (( i = 0; i < ${#files[@]} ; ++i )); do
        (
          local file="${files[$i]}"
          if [[ "${file}" ]]; then
            local filedir filename
            filedir="$(dirname "${install_sharedir}/${file}")"
            filename="$(basename "${file}")"
            bpkg_save_remote_file "${url}/${file}" "${filedir}/${filename}" "${auth_param}"
          fi
        )
      done
    fi
  fi
  return 0
}

## outut usage
_usage () {
  echo 'usage: bpkg-install [-h|--help]'
  echo '   or: bpkg-install [-g|--global] [-b|--break-mode] [-n|--no-deps] <package>'
  echo '   or: bpkg-install [-g|--global] [-b|--break-mode] [-n|--no-deps] <user>/<package>'
}

## check parameter consistency
_validate_parameters () {
  if [[ ${#BPKG_GIT_REMOTES[@]} -ne ${#BPKG_REMOTES[@]} ]]; then
    mesg='BPKG_GIT_REMOTES[%d] differs in size from BPKG_REMOTES[%d] array'
    fmesg=$(printf "$mesg" "${#BPKG_GIT_REMOTES[@]}" "${#BPKG_REMOTES[@]}")
    bpkg_error "$fmesg"
    return 1
  fi
  return 0
}

## Install a bash package
bpkg_install () {
  local pkg=''
  local needs_global=0
  local break_mode=0
  local needs_deps=1
  local auth_info=''

  for opt in "${@}"; do
    if [[ '-' = "${opt:0:1}" ]]; then
      continue
    fi
    pkg="${opt}"
    break
  done

  for opt in "${@}"; do
    case "${opt}" in
      -h|--help)
        _usage
        return 0
        ;;

      -g|--global)
        shift
        needs_global=1
        ;;

      -b|--break-mode)
        shift
        break_mode=1
        ;;

      -n|--no-deps)
        shift
        needs_deps=0
        ;;
      *)
        if [[ '-' = "${opt:0:1}" ]]; then
          echo 2>&1 "error: Unknown argument \`${1}'"
          _usage
          return 1
        fi
        ;;
    esac
  done

  ## ensure there is a package to install
  if [[ -z "${pkg}" ]]; then
    _usage
    return 1
  fi

  echo

  if bpkg_is_local_path "${pkg}"; then
    #shellcheck disable=SC2164
    pkg="file://$(cd "${pkg}"; pwd)"
  fi

  if bpkg_has_auth_info "${pkg}"; then
    auth_info="$(bpkg_parse_auth_info "${pkg}")"
    bpkg_debug "auth_info" "${auth_info}"

    pkg="$(bpkg_remove_auth_info "${pkg}")"
    bpkg_debug "pkg" "${pkg}"
  fi

  if bpkg_is_full_url "${pkg}"; then
    bpkg_debug "parse" "${pkg}"

    local bpkg_remote_proto bpkg_remote_host bpkg_remote_path bpkg_remote_uri

    bpkg_remote_proto="$(bpkg_parse_proto "${pkg}")"

    if bpkg_is_local_path "${pkg}"; then
      bpkg_remote_host="/$(bpkg_parse_host "${pkg}")"
    else
      bpkg_remote_host="$(bpkg_parse_host "${pkg}")"
    fi

    bpkg_remote_path=$(bpkg_parse_path "${pkg}")
    bpkg_remote_uri="${bpkg_remote_proto}://${bpkg_remote_host}"

    bpkg_debug "proto" "${bpkg_remote_proto}"
    bpkg_debug "host" "${bpkg_remote_host}"
    bpkg_debug "path" "${bpkg_remote_path}"

    BPKG_REMOTES=("${bpkg_remote_uri}" "${BPKG_REMOTES[@]}")
    BPKG_GIT_REMOTES=("${bpkg_remote_uri}" "${BPKG_GIT_REMOTES[@]}")
    pkg="$(echo "${bpkg_remote_path}" | bpkg_esed "s|^\/(.*)|\1|")"

    if bpkg_is_coding_net "${bpkg_remote_host}"; then
      # update /u/{username}/p/{project} to {username}/{project}
      bpkg_debug "reset pkg for coding.net"
      pkg="$(echo "${pkg}" | bpkg_esed "s|\/?u\/([^\/]+)\/p\/(.+)|\1/\2|")"
    fi

    bpkg_debug "pkg" "${pkg}"
  fi

  ## Check each remote in order
  local i=0
  for remote in "${BPKG_REMOTES[@]}"; do
    local git_remote=${BPKG_GIT_REMOTES[$i]}
    _bpkg_install_from_remote "$pkg" "$remote" "$git_remote" $needs_global $break_mode $needs_deps "$auth_info"
    if [[ "$?" == '0' ]]; then
      return 0
    elif [[ "$?" == '2' ]]; then
      bpkg_error 'fatal error occurred during install'
      return 1
    fi
    i=$((i+1))
  done
  bpkg_error 'package not found on any remote'
  return 1
}

## Use as lib or perform install
if [[ ${BASH_SOURCE[0]} != $0 ]]; then
  export -f bpkg_install
elif _validate_parameters; then
  bpkg_install "${@}"
  exit $?
else
  #param validation failed
  exit $?
fi
