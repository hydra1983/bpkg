#!/bin/bash

# Include config rc file if found
CONFIG_FILE="$HOME/.bpkgrc"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

## set defaults
if [[ ${#BPKG_REMOTES[@]} -eq 0 ]]; then
  BPKG_REMOTES[0]=${BPKG_REMOTE-https://raw.githubusercontent.com}
  BPKG_GIT_REMOTES[0]=${BPKG_GIT_REMOTE-https://github.com}
fi
BPKG_USER="${BPKG_USER:-bpkg}"

function _is_osx(){
  if [[ "$(uname -a | grep "Darwin")" != "" ]] ; then
    return 0
  else
    return 1
  fi
}

function _esed(){
  if _is_osx; then
    sed -E "$@"
  else
    sed -r "$@"
  fi
}

## check parameter consistency
validate_parameters () {
  if [[ ${#BPKG_GIT_REMOTES[@]} -ne ${#BPKG_REMOTES[@]} ]]; then
    mesg='BPKG_GIT_REMOTES[%d] differs in size from BPKG_REMOTES[%d] array'
    fmesg=$(printf "$mesg" "${#BPKG_GIT_REMOTES[@]}" "${#BPKG_REMOTES[@]}")
    error "$fmesg"
    return 1
  fi
  return 0
}

## outut usage
usage () {
  echo 'usage: bpkg-install [-h|--help]'
  echo '   or: bpkg-install [-g|--global] <package>'
  echo '   or: bpkg-install [-g|--global] <user>/<package>'
}

## format and output message
message () {
  if type -f bpkg-term > /dev/null 2>&1; then
    bpkg-term color "${1}"
  fi

  shift
  printf "    ${1}"
  shift

  if type -f bpkg-term > /dev/null 2>&1; then
    bpkg-term reset
  fi

  printf ': '

  if type -f bpkg-term > /dev/null 2>&1; then
    bpkg-term reset
    bpkg-term bright
  fi

  printf "%s\n" "${@}"

  if type -f bpkg-term > /dev/null 2>&1; then
    bpkg-term reset
  fi
}

## output error
error () {
  {
    message 'red' 'error' "${@}"
  } >&2
}

## output warning
warn () {
  {
    message 'yellow' 'warn' "${@}"
  } >&2
}

## output info
info () {
  local title='info'
  if (( "${#}" > 1 )); then
    title="${1}"
    shift
  fi
  message 'cyan' "${title}" "${@}"
}

## output debug
debug () {
  local title='info'
  if (( "${#}" > 1 )); then
    title="${1}"
    shift
  fi
  message 'green' "${title}" "${@}"
}


save_remote_file () {
  local auth_param path url

  url="${1}"
  path="${2}"
  auth_param="${3:-}"
  
  debug "fetch" "${url}"
  debug "write" "${path}"
  
  local filedir="$(dirname ${path})"
  if [[ ! -d "${filedir}" ]]; then
    mkdir -p "${filedir}"
  fi

  if [[ "${auth_param}" ]];then
    curl --silent -L -o "${path}" -u "${auth_param}" "${url}"
  else
    curl --silent -L -o "${path}" "${url}"
  fi
}


url_exists () {
    local auth_param exists url

    url="${1}"
    auth_param="${2:-}"
    exists=0

    debug "check" "${url}"

    if [[ "${auth_param}" ]];then
      status=$(curl --silent -L -w '%{http_code}' -o '/dev/null' -u "${auth_param}" "${url}")
      result="$?"
    else
      status=$(curl --silent -L -w '%{http_code}' -o '/dev/null' "${url}")
      result="$?"
    fi

    # In some rare cases, curl will return CURLE_WRITE_ERROR (23) when writing
    # to `/dev/null`. In such a case we do not care that such an error occured.
    # We are only interested in the status, which *will* be available regardless.
    if [[ '0' != "${result}" && '23' != "${result}" ]] || (( status >= 400 )); then
      exists=1
    fi

    return "${exists}"
}

read_package_json () {
  local auth_param url

  url="${1}"
  auth_param="${2:-}"
  
  if [[ "${auth_param}" ]];then
    curl --silent -L -u "${auth_param}" "${url}"
  else
    curl --silent -L "${url}"
  fi
}

is_coding_net () {
  local remote="$1"

  if [[ "$(echo ${remote} | grep 'coding.net')" ]]; then
    return 0
  else
    return 1
  fi
}

is_github_raw () {
  local remote="$1"

  if [[ "$(echo ${remote} | grep raw.githubusercontent.com)" ]]; then
    return 0
  else
    return 1
  fi
}

is_full_url () {
  local url=$1
  if [[ "$(echo \"${url}\" | egrep '[^/]+:\/\/.*')" != "" ]]; then
    return 0
  else
    return 1
  fi
}

parse_proto () {
  local url="$1"
  echo "${url}" | _esed "s|([^\/""]+):\/\/([^\/]+)(\/.*)|\1|"
}

parse_host () {
  local url="$1"
  echo "${url}" | _esed "s|([^\/]+):\/\/([^\/]+)(\/.*)|\2|"
}

parse_path () {
  local url="$1"
  echo "${url}" | _esed "s|([^\/]+):\/\/([^\/]+)(\/.*)|\3|"
}

wrap_script () {
  local src dest src_content src_shabang tmp_script_file dest_name
  
  src="$1"
  dest="$2"
  src_content=$(cat ${src})
  dest_name=$(basename ${dest})

  if [[ "$(cat ${src} | head -n 1 | grep '#!')" ]]; then
    src_shabang=$(cat ${src} | head -n 1)
    src_content=$(cat ${src} | tail -n +2)
  else
    src_shabang="#!/usr/local/bin/bash"
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

# Load module
function __load () {
  local module_file script_file script_dir script_name
    
  script_file="\$1"
  module_file="\$2"  
  
  if [[ -L \${script_file} ]] ; then
      script_dir=\$(cd \$(dirname \$(readlink -f \${script_file})); pwd)
  else
      script_dir=\$(cd \$(dirname \${script_file}); pwd)
  fi

  script_name="\$(basename \${script_file})"

  if [[ -d "\${script_dir}/../share/\${script_name}" ]]; then
      script_dir="\$(cd "\${script_dir}/../share/\${script_name}"; pwd)"
  fi

  source "\${script_dir}/\${module_file}"
}
#########################################
EOF

  echo "${src_content}" | tee -a "${tmp_script_file}" > /dev/null

  cp -f "${tmp_script_file}" "${dest}"
  chmod +x "${dest}"

  rm -f "${tmp_script_file}"
}

## Install a bash package
bpkg_install () {
  local pkg=''
  local let needs_global=0

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
        usage
        return 0
        ;;

      -g|--global)
        shift
        needs_global=1
        ;;

      *)
        if [[ '-' = "${opt:0:1}" ]]; then
          echo 2>&1 "error: Unknown argument \`${1}'"
          usage
          return 1
        fi
        ;;
    esac
  done

  ## ensure there is a package to install
  if [[ -z "${pkg}" ]]; then
    usage
    return 1
  fi

  echo

  if is_full_url "${pkg}"; then
    debug "parse" "${pkg}"

    local bpkg_remote_proto="$(parse_proto "${pkg}")"
    local bpkg_remote_host="$(parse_host "${pkg}")"
    local bpkg_remote_path=$(parse_path "${pkg}")
    local bpkg_remote_uri="${bpkg_remote_proto}://${bpkg_remote_host}"
    
    debug "proto" "${bpkg_remote_proto}"
    debug "host" "${bpkg_remote_host}"
    debug "path" "${bpkg_remote_path}"

    BPKG_REMOTES=("${bpkg_remote_uri}" "${BPKG_REMOTES[@]}")
    BPKG_GIT_REMOTES=("${bpkg_remote_uri}" "${BPKG_GIT_REMOTES[@]}")
    pkg="$(echo "${bpkg_remote_path}" | _esed "s|^\/(.*)|\1|")"

    if is_coding_net "${bpkg_remote_host}"; then
      # update /u/{username}/p/{project} to {username}/{project}
      info "reset pkg for coding.net"
      pkg="$(echo ${pkg} | _esed "s|\/?u\/([^\/]+)\/p\/(.+)|\1/\2|")"      
    fi

    debug "pkg" "${pkg}"
  fi

  ## Check each remote in order
  local let i=0
  for remote in "${BPKG_REMOTES[@]}"; do
    local git_remote=${BPKG_GIT_REMOTES[$i]}
    bpkg_install_from_remote "$pkg" "$remote" "$git_remote" $needs_global
    if [[ "$?" == '0' ]]; then
      return 0
    elif [[ "$?" == '2' ]]; then
      error 'fatal error occurred during install'
      return 1
    fi
    i=$((i+1))
  done
  error 'package not found on any remote'
  return 1
}

## try to install a package from a specific remote
## returns values:
##   0: success
##   1: the package was not found on the remote
##   2: a fatal error occurred
bpkg_install_from_remote () {
  local pkg=$1
  local remote=$2
  local git_remote=$3
  local let needs_global=$4

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
  local let has_pkg_json=1
  declare -a local pkg_parts=()
  declare -a local remote_parts=()
  declare -a local scripts=()
  declare -a local files=()
  
  ## get version if available
  {
    OLDIFS="${IFS}"
    IFS="@"
    pkg_parts=(${pkg})
    IFS="${OLDIFS}"
  }

  if [[ ${#pkg_parts[@]} -eq 1 ]]; then
    version='master'
    #info "Using latest (master)"
  elif [[ ${#pkg_parts[@]} -eq 2 ]]; then
    name="${pkg_parts[0]}"
    version="${pkg_parts[1]}"
  else
     error 'Error parsing package version'
    return 1
  fi

  ## split by user name and repo
  {
    OLDIFS="${IFS}"
    IFS='/'
    pkg_parts=(${pkg})
    IFS="${OLDIFS}"
  }

  if [[ ${#pkg_parts[@]} -eq 1 ]]; then
    user="${BPKG_USER}"
    name="${pkg_parts[0]}"
  elif [[ ${#pkg_parts[@]} -eq 2 ]]; then
    user="${pkg_parts[0]}"
    name="${pkg_parts[1]}"
  elif [[ ${#pkg_parts[@]} -eq 3 ]]; then
    user="${pkg_parts[0]}/${pkg_parts[1]}"
    name="${pkg_parts[2]}"
  else
    error 'Unable to determine package name'
    return 1
  fi

  ## clean up name of weird trailing
  ## versions and slashes
  name=${name/@*//}
  name=${name////}

  ## check to see if remote is raw with oauth (GHE)
  if [[ "${remote:0:10}" == "raw-oauth|" ]]; then
    info 'Using OAUTH basic with content requests'
    OLDIFS="${IFS}"
    IFS="'|'"
    local remote_parts=($remote)
    IFS="${OLDIFS}"
    local token=${remote_parts[1]}
    remote=${remote_parts[2]}
    auth_param="$token:x-oauth-basic"
    uri="/${user}/${name}/raw/${version}"
    ## If git remote is a URL, and doesn't contain token information, we
    ## inject it into the <user>@host field
    if [[ "$git_remote" == https://* ]] && [[ "$git_remote" != *x-oauth-basic* ]] && [[ "$git_remote" != *${token}* ]]; then
      git_remote=${git_remote/https:\/\//https:\/\/$token:x-oauth-basic@}
    fi
  elif is_coding_net "${remote}"; then
    uri="/u/${user}/p/${name}/git/raw/${version}"
  elif is_github_raw "${remote}"; then
    uri="/${user}/${name}/${version}"
  else 
    uri="/${user}/${name}/raw/${version}"    
  fi

  ## clean up extra slashes in uri
  uri=${uri/\/\///}
  info "Install $uri from remote $remote [$git_remote]"

  ## Ensure remote is reachable
  ## If a remote is totally down, this will be considered a fatal
  ## error since the user may have intended to install the package
  ## from the broken remote.
  {
    if ! url_exists "${remote}" "${auth_param}"; then
      error "Remote unreachable: ${remote}"
      return 2
    fi
  }

  ## build url
  url="${remote}${uri}"
  
  if is_coding_net "${remote}"; then
    repo_url="${git_remote}/u/${user}/p/${name}/git"
  else
    repo_url="${git_remote}/${user}/${name}.git"
  fi
  
  ## determine if 'package.json' exists at url
  {
    if ! url_exists "${url}/package.json?$(date +%s)" "${auth_param}"; then
      warn 'package.json doesn`t exist'
      has_pkg_json=0
      # check to see if there's a Makefile. If not, this is not a valid package
      if ! url_exists "${url}/Makefile?$(date +%s)" "${auth_param}"; then
        warn "Makefile not found, skipping remote: $url"
        return 1
      fi
    fi
  }

  ## read package.json
  json=$(read_package_json "${url}/package.json?$(date +%s)" "${auth_param}")

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
    if [[ ! -"z $(echo -n "${json}" | bpkg-json -b | grep '\["global"\]' | awk '{ print $2 }' | tr -d '"')" ]]; then
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

  ## build global if needed
  if (( 1 == needs_global )); then
    if (( 1 == has_pkg_json )); then
      ## install bin if needed
      build="$(echo -n "${json}" | bpkg-json -b | grep '\["install"\]' | awk '{$1=""; print $0 }' | tr -d '\"')"
      build="$(echo -n "${build}" | sed -e 's/^ *//' -e 's/ *$//')"
    fi

    if [[ -z "${build}" ]]; then
      warn 'Missing build script'
      warn 'Trying `make install`...'
      build='make install'
    fi

    { (
      ## go to tmp dir
      cd "$( [[ ! -z "${TMPDIR}" ]] && echo "${TMPDIR}" || echo /tmp)" &&
       ## prune existing
      rm -rf "${name}-${version}" &&
      ## shallow clone
      info "Cloning ${repo_url} to ${name}-${version}" &&
      git clone "${repo_url}" "${name}-${version}" &&
      (
        ## move into directory
        cd "${name}-${version}" &&
        git checkout ${version} &&
        ## wrap
        for script in $scripts; do (
            local script="$(echo $script | xargs basename )"

            if [[ "${script}" ]];then\
              cp -f "$(pwd)/${script}" "$(pwd)/${script}.orig"
              wrap_script "$(pwd)/${script}.orig" "$(pwd)/${script}"
            fi
        ) done &&
        ## build
        info "Performing install: \`${build}'" &&
        eval "${build}"
      ) &&
      ## clean up
      rm -rf "${name}-${version}"
    ) }
  ## perform local install otherwise
  else
    ## copy package.json over    
    save_remote_file "${url}/package.json" "${cwd}/deps/${name}/package.json" "${auth_param}"

    ## make 'deps/' directory if possible
    mkdir -p "${cwd}/deps/${name}"

    ## make 'deps/bin' directory if possible
    mkdir -p "${cwd}/deps/bin"

    # install package dependencies
    (cd "${cwd}/deps/${name}" && bpkg getdeps)

    ## grab each script and place in deps directory    
    for script in $scripts; do
      (
        local script="$(echo $script | xargs basename )"

        if [[ "${script}" ]];then          
          save_remote_file "${url}/${script}" "${cwd}/deps/${name}/${script}" "${auth_param}"
          local scriptname="${script%.*}"
          info "${scriptname} to PATH" "${cwd}/deps/bin/${scriptname}"
          cp -f "${cwd}/deps/${name}/${script}" "${cwd}/deps/${name}/${script}.orig"
          wrap_script "${cwd}/deps/${name}/${script}.orig" "${cwd}/deps/${name}/${script}"
          ln -sf "${cwd}/deps/${name}/${script}" "${cwd}/deps/bin/${scriptname}"          
          chmod u+x "${cwd}/deps/bin/${scriptname}"
        fi
      )
    done

    if [[ "${#files[@]}" -gt '0' ]]; then
      ## grab each file
      for (( i = 0; i < ${#files[@]} ; ++i )); do
        (
          local file="${files[$i]}"
          if [[ "${file}" ]];then
            local filedir="$(dirname "${cwd}/deps/${name}/${file}")"
            local filename="$(basename "${file}")"            
            save_remote_file "${url}/${file}" "${filedir}/${filename}" "${auth_param}"
          fi
        )
      done
    fi
  fi
  return 0
}

## Use as lib or perform install
if [[ ${BASH_SOURCE[0]} != $0 ]]; then
  export -f bpkg_install
elif validate_parameters; then
  bpkg_install "${@}"
  exit $?
else
  #param validation failed
  exit $?
fi
