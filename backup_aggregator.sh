#!/bin/bash
#
#  Title:               Backup_Aggregator
#
#  Version:             1.0.4
#
#  File:                /opt/scripts/backup_aggregator.sh
#
#  Description:         This script aggregates backups from the Remote
#                       Collectors of a particalular environment and stores it
#                       in the local backups folder.
#
#
#  Syntax:              backup_aggregator.sh -<flags> -<option> <argument>
#
#               EX:     Run the script in debugging and no change mode.
#
#                               backup_aggregator.sh -dn
#
#                       Run the script and sync copied files to another server.
#                       NOTE: Other server must have a /data/backups directory
#
#                               backup_aggregator.sh -s "<server_name>"
#
#                       Run the script with non-default source, file pattern,
#                       or destination.
#
#                               backup_aggregator.sh /some/dir/on/remote/ '*os_backup*' /some/local/dir/
#
#  Dependencies:        spse_functions.sh, /usr/bin/rsync, /dev/tcp, /etc/hosts
#
#  Supported Platforms: Redhat 7.4
#
#  Author:              Daniel Bergstrom
#
#  Business Unit:       Security Intelligence Engineering
#
#  History:
#
#    2/13/2017 v1.0.0 - Created Script. (Daniel Bergstrom)
#    3/01/2017 v1.0.1 - Add debugging line for seeing rsync raw output along
#                       with the file copied in the log. (Daniel Bergstrom)
#    3/22/2017 v1.0.2 - Added explanations for other uses in script description
#                       Fix various lines with known pattern matching issues in later Bash versions
#   11/12/2021 v1.0.3 - Added cleaning of destination directory before syncing files. And now sync_files only syncs the number of days specified (Daniel Bergstrom)
#   11/15/2021 v1.0.4 - Add Retention time variable as script parameter (Daniel Bergstrom)
#   12/07/2021 v1.0.5 - Add rsync option to preserve mtime (Daniel Bergstrom)
#   03/31/2023 v1.0.6 - Add --old-args option to rsync to handle newer versions of rsync
#
#  Notes:
#                       Script pulls servers from hosts file.
#
#                       Source parameter is the directory of the remote source it
#                       determines from the hosts file. Be sure to have a
#                       trailing '/' at the end of the directory!!
#
#                       Pattern parameter is the filename or filename pattern
#                       to use in searching.
#
#                       Destination is the local directory to copy to. Be sure
#                       to have a trailing '/' at the end of the directory!!
#
#
################################################################################

################################################################################
#
#  CONFIGURATION:
#
#  Readonly/Global variables
#
################################################################################
readonly VALID_VARNAME='^[a-zA-Z_][a-zA-Z0-9_]*$' # describes a valid variable
                                                  #   name regex.
readonly ACCOUNT='splunk'                           # Account used to pull backups
                                                  #   over.
# Temp storage for file names synced from all the remote locations
readonly TMP_FILE='/tmp/backup_aggregator_sync_file.txt'

# Recipient(s) for email alerts
readonly RECIPIENTS="grp_SPSE@intel.com"

BASE_BACKUP_SOURCE='/data/backups/'           # Backup_source is appended on a
                                         #  hostname when actually used.
BACKUP_DESTINATION='/data/backups/'      # Points to local /data/backups/

FILE_REGEX='*_backup*'                   # Regex used to match files to
                                         #   be pulled
FILE_AGE_RETENTION_IN_DAYS='7'

# Base message for alert email body
mail_msg="Script failed to pull backups. Reason(s): "

debug_flag=false        # set whether or not debug messages are logged.
error_flag=false        # flag for whether script errors have happened.
sync_flag=false         # flag for if the script will sync to another system.

env=""                  # the environment that the script is running in (p,q,d)
sync_target=""          # variable for system targets for syncing, if set
servers=()              # variable to hold list of servers

rsync_opts="-it"         # options/flags for rsync to run with

################################################################################
#
#  Load libraries
#
################################################################################
. /opt/lib/spse_functions.sh

################################################################################
#
#  Function definitions
#
################################################################################
#==============================================================================#

################################################################################
#
#  Function:    Displays usage of the script
#
#  Arguments:   <none>
#
#  Global variables:
#       $0 - full path to the script
#
################################################################################

function display_usage(){
    echo -e ""
    echo -e " Usage: `basename $0` -<flags> -<options> [<source> <pattern> <destination> <retention_time_in_days>]"
    echo -e ""
    echo -e " source, pattern, destination and retention time parameters are optional. "
    echo -e " However, if you're using a custom setting of any of the 4, "
    echo -e "   they are all required."
    echo -e ""
    echo -e " When using source, pattern and destination params, don't enter "
    echo -e " them as UPNs. Only as directory with trailing '/'."
    echo -e ""
    echo -e " When using defaults, the script will automatically assume: "
    echo -e "   source:         /data/backups/ "
    echo -e "   pattern:        *_backups* "
    echo -e "   destination:    /data/backups/ "
    echo -e "   retention_time: 7 "
    echo -e ""
    echo -e " Script will pull systems to aggregate the backups from, from the /etc/hosts file"
    echo -e "   if a source backup is missing, check the /etc/hosts file"
    echo -e ""
    echo -e " Options: "
    echo -e " -----------------------------------------------------------------"
    echo -e "  h - Help/display usage"
    echo -e "  d - Run in debug mode. Logs all debug messages."
    echo -e "  n - No changes mode. Will run normally but without actually"
    echo -e "      making changes."
    echo -e ""
}


################################################################################
#
#  Function:    Handle supplied parameters to script
#
#  Arguments:
#     0 Arguments:
#     -----------
#       All default settings at the top of script will be used.
#
#     4 Arguments:
#     -----------
#       $1 - Backup source
#       $2 - Pattern/filename used to determine what file(s) to backup
#       $3 - Backup destination
#       $4 - Retention time in days
#
#  Returns:
#       0 : success
#       1 : general error
#
################################################################################

function handle_script_parameters(){
    local param_count="$#"

    case "$param_count" in
        0)
          # run script with default values
          # grab remote servers in same env, src/dest = '/data/backups'
          ;;
        4)
          BASE_BACKUP_SOURCE="$1"
          FILE_REGEX="$2"
          BACKUP_DESTINATION="$3"
          FILE_AGE_RETENTION_IN_DAYS="$4"

          if [ -z "${BASE_BACKUP_SOURCE// }" ] ||
             [ -z "${FILE_REGEX// }" ]    ||
             [ -z "${BACKUP_DESTINATION// }" ];
             [ -z "${FILE_AGE_RETENTION_IN_DAYS// }" ];
          then
             write_log "ERROR" "Empty or invalid parameters supplied to script."
             error_flag=true
             return 1
          fi
          ;;
        *)
          write_log "ERROR" "Incorrect amount of parameters supplied to script."
          error_flag=true
          return 1
          ;;
    esac

return 0
}

#######################################################################################################################################################
#
#  Function: write_log()
#
#  Description: Write message to log file.
#
#  Arguments:
#    $1 - category/severity. Acceptable values are TRACE, DEBUG, INFO, WARNING, ERROR, CRITICAL.
#    $2 - message to be written to log file
#
#  Global variables:
#    $0 - full path of script
#
#  Returns: 0 or 1
#
#  Example of usage:
#    message="This is a test message."
#    write_log "INFO" "$message"
#
#######################################################################################################################################################

write_log () {
  local l_fName=`basename $0`                    # Extract the file name with extension
  l_fName=${l_fName%.*}                          # Strip shortest match .* off end of string (strips extension off)
  local l_LOG_DIR=/var/log/                      # Set the log directory
  local l_LOG_FN=/var/log/"$l_fName".log         # Set log file name to <script name without extension>_<date in YYMMDD format>.log

  # If the log directory and log file do not exist, then create the directory and file and set the appropriate owner, group, and access permissions

  if [ ! -d "$l_LOG_DIR" ]; then
    mkdir -p $l_LOG_DIR
    chmod 750 $l_LOG_DIR
    touch $l_LOG_FN
    chmod 640 $l_LOG_FN
  fi

  # Write message to log file

  MSG=`date "+%Y-%m-%d %H:%M:%S %Z %:z"`" $1 $2"
  echo $MSG >> $l_LOG_FN
}


################################################################################
#
#  Function:    Checks and sets the environment that the script is running under
#               based on the hostname (i.e: p,q,d)
#
#  Arguments:   <none>
#
#  Global variables:
#       $0 - full path to the script
#
#  Return:
#       0 : success
#       1 : general error
#
################################################################################

function set_environment(){
    case `hostname|cut -c 4|awk '{print toupper($0)}'` in
        D)
           env='d'
           ;;
        Q)
           env='q'
           ;;
        P)
           env='p'
           ;;
        *)
           env='#'
           return 1
           ;;
    esac

    return 0
}

################################################################################
#
#  Function: Get list of servers parsed from local hosts file
#
#  Arguments:
#       $1 - the variable name you want the server list stored in as an array
#
#  Return:
#       0 : success
#       1 : general error
#
#  Notes:
#       only grabs servers from local hostfile that follow a pattern (for example) like
#             ###+AAABBB### where + = {p,q,d}
#
################################################################################

function get_servers(){
    if [[ "$#" -ne "1" ]]; then
        write_log "ERROR" "Invalid amount of parameters used in get_servers()"
        return 1
    fi

    # file to read server info from
    declare -r file_loc="/etc/hosts"

    # line from file has to start with 1 to 3 numbers (i.e. IPv4 address)
    local HOSTNAME_REGEX="^[0-9]{1,3}.*[a-z]{3}${env}spk[a-z]{3}[0-9]{3}"
    local server_varname=$1
    local server_list=()

    if [[ -z ${server_varname// } ]] || \
       [[ ! $server_varname =~ $VALID_VARNAME ]];
    then
        if $debug_flag; then
            write_log "DEBUG" "get_servers() error: invalid variable name '$server_varname' used for server list variable.";
        fi
        return 1
    fi

    if [ -e $file_loc ];
    then
        if $debug_flag; then
            write_log "DEBUG" "Reading $file_loc for server info...";
        fi

        server_list=$(cat $file_loc | grep -E $HOSTNAME_REGEX | sed 's/\t/ /g')

    else
        log_msg="$0: File containing server info (${file_loc}) can't be found or doesn't exist."
        error_flag=true
        mail_msg=`echo -e "${mail_msg}\nERROR: ${log_msg}"`
        write_log "ERROR" "$log_msg"
        return 1
    fi

    eval $server_varname="'${server_list}'"

    return 0
}

################################################################################
#
#  Function: Tests whether or not the server is reachable/has an open port 22
#
#  Arguments:
#      $1 - the name/ip of the server that will be used in the connection test
#
#  Returns:
#       0 : success
#       1 : general error
#       2 : server unreachable/port closed
#
#  Notes:
#
################################################################################

function test_server_conn(){
    local server_address=$1
    if [[ "$#" -ne "1" ]] || \
       [[ -z "${server_address// }" ]];
    then
        if $debug_flag; then
            write_log "DEBUG" "invalid input for testing server connection";
        fi
        return 1
    fi

    if $debug_flag; then
        write_log "DEBUG" "Checking if port 22 is open on $server_address";
    fi

    # Check if server port 22 is open
    (exec 3<>/dev/tcp/${server_address}/22) &>/dev/null

    if [ "$?" -eq "0" ];
    then
        if $debug_flag; then
            write_log "DEBUG" "${server_address}:22 open. Assuming ssh connection possible";
        fi
    else
        if $debug_flag; then
            write_log "DEBUG" "${server_address}:22 closed or unreachable. Ssh connection not possible";
        fi

        exec 3>&-
        return 2
    fi


    # close file descriptor used for tcp:port test
    exec 3>&-

    return 0
}

################################################################################
#
#  Function: Parses through the output from rsync and builds a comma delimited
#            list.
#
#  Arguments:
#       $1 - the name for the variable that will store list of files
#       $2 - the output from rsync
#
#  Returns:
#        0 : success
#        1 : general error
#
################################################################################

function parse_rsync_output(){
    local file_list_varname=$1
    local rsync_output=$2

    if [[ "$#" -ne "2" ]];
    then
        if $debug_flag; then
            write_log "DEBUG" "Invalid amount of parameters passed to parse_rsync_output function"
        fi
        return 1
    fi

    if [[ -z "${file_list_varname// }" ]] || \
       [[ ! $file_list_varname =~ $VALID_VARNAME ]];
    then
        if $debug_flag; then
            write_log "DEBUG" "Invalid input for parse_rsync_output function"
        fi

        return 1
    fi

    local files=""
    # parse out the files that were successfully copied from rsync output
    while read line;
    do
        local cols=($line)

        if [ $debug_flag = "true" ] &&
           [ ! -z ${cols[0]// } ]   &&
           [ ! -z ${cols[1]// } ];
        then
            files="${files}(${cols[0]})"
        fi

        files="${files}${cols[1]},"
    done <<<"$rsync_output"

    # trim trailing comma off
    files=${files:0:${#files}-1}

    eval $file_list_varname="'${files}'"

    return 0
}


################################################################################
#
#  Function:    Synchronizes specified file(s) between a source and destination.
#
#  Arguments:
#    4 arguments:
#    ---------------
#       $1 - source
#           <must be in form of either: a server name, or a upn>
#       $2 - file
#       $3 - destination
#           <must be in form of either: a server name, or a upn>
#       $4 - variable name to store list of files synced/transferred
#
#    3 arguments
#       (meant to be used if files will be selected some other way.
#        E.g. a file, where a custom rsync option would be used):
#    ---------------
#       $1 - source
#           <must be in form of either: a server name, or a upn>
#       $2 - destination
#           <must be in form of either: a server name, or a upn>
#       $3 - variable name to store list of files synced/transferred
#
#  Returns:
#       0 : success
#       1 : usage or syntax error
#       2 - 35 : rsync status codes (see: man rsync)
#       100 : source directory doesn't exist
#       101 : destination directory doesn't exist
#
#  Notes:
#       If using file parameter, it must be either a single file or pattern
#           for multiple files
#
#       ex: single file:
#               sync_files /foo/bar/ somefile.file /bar/foo/ listOfFiles
#
#       ex: multiple files:
#               sync files /foo/bar/ "_files*" /bar/foo/ listOfFiles
#
#       Transfers are only:
#           local->local
#           local->remote
#           remote->local
#
#       i.e. Can't do remote->remote due to rsync
#
################################################################################

function sync_files(){
    local source=""
    local file=""
    local dest=""
    local output_var=""

    local UPN_PATTERN='\w+\@[a-zA-Z0-9_.]+\:[^\s]+'

    if [ "$#" -eq "4" ]; then
        source=$1
        file=$2
        dest=$3
        output_var=$4
    elif [ "$#" -eq "3" ]; then
        source=$1
        dest=$2
        output_var=$3
        file=""
    else
        if $debug_flag; then
            write_log "DEBUG" "Invalid parameters supplied to sync_files()"
        fi
        return 1
    fi

    if  [[ -z "${source// }" ]]     || \
        [[ -z "${dest// }" ]]       || \
        [[ -z "${output_var// }" ]];
    then
        if $debug_flag; then
            write_log "DEBUG" "Invalid input supplied to sync_files function"
        fi
        return 1
    fi

    # check if backup source exists
    if $debug_flag; then
        write_log "DEBUG" "Checking if source directory ($source) exists.";
    fi

    # check if source directory exists
    local _s_upn=""
    if [[ ${source} =~ ${UPN_PATTERN} ]];
    then
        _s_upn="${source/@/ }"
        _s_upn="${_s_upn/:/ }"
        _s_upn=(${_s_upn})

        if (ssh "${_s_upn[1]}" '[ ! -d '"$BASE_BACKUP_SOURCE"' ]' </dev/null &>/dev/null);
        then
            return 100
        fi
    else
        # if source isn't in form of upn then it must be local
        _s_upn[0]="$ACCOUNT"
        _s_upn[1]="localhost"
        _s_upn[2]="${source}"

        if [ ! -d "${source}" ]; then
            return 100
        fi
    fi

    # check if backup destination exists
    if $debug_flag; then
        write_log "DEBUG" "Checking if destination directory ($dest) exists.";
    fi

    # check if destination directory exists
    local _d_upn=""
    if [[ ${dest} =~ ${UPN_PATTERN} ]];
    then
        _d_upn="${dest/@/ }"
        _d_upn="${_d_upn/:/ }"
        _d_upn=(${_d_upn})

        if (ssh "${_d_upn[1]}" '[ ! -d '"$BACKUP_DESTINATION"' ]' </dev/null &>/dev/null);
        then
            mkdir -p ${BACKUP_DESTINATION}
            #return 101
        fi
    else
        _d_upn[0]="$ACCOUNT"
        _d_upn[1]="localhost"
        _d_upn[2]="${dest}"

        # if dest isn't in form of upn then it must be local
        if [ ! -d "${dest}" ]; then
            mkdir -p ${BACKUP_DESTINATION}
            #return 101
        fi
    fi

    # move only newer backup files from destination to source
    # NOTE: the current command copies over files that are a different size
    #       and if they're new (from the sender side)
    #       but it Should ignore if there's only a time difference.
    #
    #       if the file already exists on the local side currently it WILL be overwritten
    #       if the sender has it too and there's a size difference
    if $debug_flag && [[ ! $rsync_opts =~ .*n.* ]]; then
        # clean destination files before syncing new over
        write_log "DEBUG" "Clearing destination directory and retaining the last ${FILE_AGE_RETENTION_IN_DAYS} days"
        ssh -nq "${_d_upn[0]}@${_d_upn[1]}" "cd ${_d_upn[2]}; /bin/find . -type f -name '${file}' -mtime -${FILE_AGE_RETENTION_IN_DAYS} -delete;"
    fi

    local out=`/usr/bin/rsync -e 'ssh -q' ${rsync_opts} --size-only --old-args      \
                                 --files-from=<(ssh -nq "${_s_upn[0]}@${_s_upn[1]}" "cd ${_s_upn[2]}; /bin/find . -type f -name '${file}' -mtime -${FILE_AGE_RETENTION_IN_DAYS};") \
                                 ${source}               \
                                 ${dest}`
    local status="$?"

    # cleanup output from rsync just in case (only grabbing transferred files lines)
    out=`grep '^[\>]' <<< "$out"`

    # parse out the files that were successfully copied from rsync output
    # and place in var named _file_list
    if ! parse_rsync_output "_file_list" "$out";
    then
        msg="There was an issue while attempting to parse rsync's output."
        msg+="'Files copied:' list may be incomplete or wrong."
        write_log "WARNING" "$msg"
    fi

    eval $output_var="'${_file_list}'"

    return $status
}

################################################################################
################################################################################
##
##        SCRIPT START
##
################################################################################
################################################################################

write_log "INFO" "$0 started-------------------"

# Validate script inputs
while getopts ":dhns:" opt; do
    case $opt in
        d)
          debug_flag=true
          write_log "INFO" "!Running script in debug mode."
          ;;
        h)
          display_usage
          exit 1
          ;;
        n)
          if [[ ! $rsync_opts =~ .*n.* ]]; then
              rsync_opts=${rsync_opts}"n"
          fi
          write_log "INFO" "!Running script in no-change mode."
          ;;
        s)
          if test_server_conn $OPTARG; then
              sync_flag=true
              sync_target="$OPTARG"
              all_files=""
          else
              write_log "ERROR" "Specified sync server is unreachable or unavailable. Exiting script."
              sync_flag=false
          fi
          ;;
       \?)
          echo -e "\nInvalid option: -$OPTARG" 1>&2
          display_usage
          exit 1
          ;;
        :)
          echo -e "\nERROR: Option -$OPTARG requires an argument." 1>&2
          display_usage
          exit 1
          ;;
    esac
done
# shift off processed options
shift $((OPTIND - 1))

# handle parameters after options/flag processing
handle_script_parameters "$@"

# set environment for script to work in
if set_environment;
then
    if $debug_flag; then
        write_log "DEBUG" "Script running in the '${env}' environment";
    fi
else
    write_log "ERROR" "Environment unable to be determined for script to run in. Canceling script..."
    exit 1
fi


# get list of servers and store in servers unless error_flag is true
if [ "$error_flag" = "false" ] && \
   ! get_servers servers;
then
    log_msg="Script failed while attempting to retrieve servernames from the hosts file."
    error_flag=true
    mail_msg=`echo -e "${mail_msg}\nERROR: ${log_msg}"`
    write_log "ERROR" "$log_msg"
fi

# Iterate through all servers to check if they're up and then perform
# backup retrieval operations
while read -r server
do
    # split line from hosts file into its own array
    read -r -a server_info <<< "$server"

    # clean carriage return off of shortname field (i.e. trim off last char)
#    server_info[2]=${server_info[2]:0:${#server_info[2]}-1}

    upn="$ACCOUNT@${server_info[2]}"

    # test whether or not server is reachable.
    #    If not, flag error_flag and then log
    if ! test_server_conn ${server_info[0]};
    then
        log_msg="${server_info[2]} backup transfer skipped. "
        log_msg+="reason: connection check failed / server unreachable."
        error_flag=true
        mail_msg=`echo -e "${mail_msg}\nCRITICAL: ${log_msg}"`
        write_log "CRITICAL" "$log_msg"
        continue
    else
        if $debug_flag; then
            write_log "DEBUG" "Communication attempt to ${server_info[2]} successful.";
        fi
    fi

    if $debug_flag; then
        write_log "DEBUG" "Attempting to copy files...";
    fi



    sync_files "${upn}:${BASE_BACKUP_SOURCE}${server_info[2]}/" "${FILE_REGEX}" "${BACKUP_DESTINATION}${server_info[2]}/" file_list
    sync_status="$?"

    # check if sync returned an error
    if [[ "$sync_status" -ne "0" ]];
    then
        error_flag=true
        if [[ "$sync_status" -eq "100" ]];
        then
            log_msg="Source directory ($BASE_BACKUP_SOURCE) doesn't exist on ${server_info[2]}. Backup transfer skipped."
            mail_msg=`echo -e "${mail_msg}\nERROR: ${log_msg}"`
            write_log "ERROR" "${log_msg}"
        fi

        if [[ "$sync_status" -eq "101" ]];
        then
            log_msg="Destination directory ($BACKUP_DESTINATION) doesn't exist. Backup transfer skipped."
            mail_msg=`echo -e "${mail_msg}\nERROR: ${log_msg}"`
            write_log "ERROR" "${log_msg}"
        fi

        log_msg="Failure attempting to copy backups from ${server_info[2]} to $BACKUP_DESTINATION."
        mail_msg=`echo -e "${mail_msg}\nCRITICAL: ${log_msg}."`
        write_log "CRITICAL" "$log_msg"
        continue
    fi

    if $debug_flag; then
        write_log "DEBUG" "Copy attempt over.";
    fi

    if [ -z ${file_list// } ]; then
        file_msg="No files copied..."
    else
        file_msg="${file_list}"
    fi

    write_log "INFO" "Files copied: ${file_msg}"
    write_log "INFO" "Backup file(s) transfer completed from ${server_info[2]}:${BASE_BACKUP_SOURCE}/${server_info[2]}/${FILE_REGEX} to ${BACKUP_DESTINATION}/${server_info[2]}"

    if [ "$sync_flag" = "true" ] && \
       [ ! -z  "${file_list// }" ];
    then
        all_files="${file_list},${all_files}"
    fi

done <<< "$servers"

if [ "$sync_flag" = "true" ]; then
    if [ ! -z  "${all_files// }" ]; then
        all_files="${all_files:0:${#all_files}-1}"
    fi

    upn="${ACCOUNT}@${sync_target}"

    (
        IFS=','
        for file in ${all_files[@]};
        do
            echo -e "$file" >> "${TMP_FILE}"
        done
    )

    rsync_opts="-i --files-from=${TMP_FILE}"
    sync_files "${BASE_BACKUP_SOURCE}" "${upn}:${BACKUP_DESTINATION}" file_list
    sync_status="$?"

    case $sync_status in
        0)
          if [ -f "${TMP_FILE}" ]; then
              rm "${TMP_FILE}"
          fi

          write_log "INFO" "Files synced to ${sync_target}: ${file_list} "
          ;;
      100)
          error_flag=true
          log_msg="Sync source directory (${BASE_BACKUP_SOURCE}) doesn't exist"
          mail_msg=`echo -e "${mail_msg}\nERROR: ${log_msg}"`
          write_log "ERROR" "${log_msg}"
          ;;
      101)
          error_flag=true
          log_msg="Sync destination directory (${BACKUP_DESTINATION}) doesn't exist"
          mail_msg=`echo -e "${mail_msg}\nERROR: ${log_msg}"`
          write_log "ERROR" "${log_msg}"
          ;;
        *)
          error_flag=true
          log_msg="$0 has returned an error while attempting to sync to another server: ${sync_status}"
          write_log "ERROR" "${log_msg}"
          mail_msg=`echo -e "${mail_msg}\nERROR: ${log_msg}"`
          ;;
    esac
fi

# Send email alert out if there have been any errors
if [ "$error_flag" = "true" ]; then
    subject="$0 has failed to complete on `hostname`"
    #send_mail_message "$subject" "$mail_msg" "$RECIPIENTS"

    if [[ "$?" -ne "0" ]];
    then
        write_log "ERROR" "Failed to send alert email to $RECIPIENTS"
    else
        write_log "INFO" "Email alert sent to $RECIPIENTS detailing script errors"
    fi

    echo -e "$0 has exited with errors. Please check the log in /var/log/intel/backup_aggregator/ for error information:" 1>&2
fi

# clear variables
unset server       \
      servers      \
      server_info  \
      line         \
      upn          \
      rsync_opts   \
      rsync_out    \
      sync_status  \
      file_list    \
      file_msg     \
      mail_msg

write_log "INFO" "$0 ended---------------------"
