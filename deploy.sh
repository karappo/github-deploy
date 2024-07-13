#!/bin/bash

# ----------------
# methods


log_label="[DEPLOY] "
log()
{
  echo "$log_label$1"
}

do_sync()
{
  # ----------------
  # Before Sync

  if type before_sync 1>/dev/null 2>/dev/null; then
    # detect before_sync method
    echo -n "$log_label- before_sync -> Processing..."
    before_sync
    log " -> Done."
  fi

  # ----------------
  # Sync

  log "- sync -> Start with $DEP_COMMAND. This could take a while..."

  # download defaults if ignore file isn't exists
  if [ ${DEP_IGNORE_FILE:-isnil} = "isnil" -o ! -f "$DEP_IGNORE_FILE" ]; then
    log "| Downloading default ignore file..."
    if wget -O .depignore https://raw.githubusercontent.com/karappo/drone-deploy/drone-compatible/v0.8/.depignore; then
      log "| -> Done."
      DEP_IGNORE_FILE=$PWD/.depignore
    else
      log "| -> [ERROR]"
      exit 1
    fi
  fi

  log "- ignore file -> $DEP_IGNORE_FILE"

  if [ "$DEP_COMMAND" = "rsync" ]; then

    # ------
    # rsync

    opt_exclude=''
    if [ -f "$DEP_IGNORE_FILE" ]; then
      opt_exclude="--exclude-from=$DEP_IGNORE_FILE"
    fi

    if [ "${DEP_PASSWORD:+isexists}" = "isexists" ]; then
      log '- rsync with password'
      if sshpass -p "$DEP_PASSWORD" rsync -aIzh --perms --owner --group --stats --delete -e ssh "$opt_exclude" . "$DEP_USER@$DEP_HOST:$DEP_HOST_DIR"; then
        log "- sync -> done."
      else
        log "- sync -> [ERROR]"
        exit 1
      fi
    else
      log '- rsync without password'

      # MEMO
      # 下記の場合わけで差分は'-e "ssh -p $DEP_PORT"'の部分だけだが、事前に文字列にして変数に入れて実行時に展開するやり方（$opt_excludeのような）だと、うまく動かなかった。
      # 変数展開したときにクォート系がちゃんと処理されていない？とにかく、どうしようもないので、実行部分を２つに分けた。
      if [ "${DEP_PORT:+isexists}" = "isexists" ]; then
        # Specific port
        log "- rsync port: $DEP_PORT"
        if rsync -aIzh --perms --owner --group --stats --delete -e "ssh -p $DEP_PORT" "$opt_exclude" . "$DEP_USER@$DEP_HOST:$DEP_HOST_DIR"; then
          log "- sync -> done."
        else
          log "- sync -> [ERROR]"
          exit 1
        fi
      else
        # Default port
        log '- rsync default port'
        if rsync -aIzh --perms --owner --group --stats --delete "$opt_exclude" . "$DEP_USER@$DEP_HOST:$DEP_HOST_DIR"; then
          log "- sync -> done."
        else
          log "- sync -> [ERROR]"
          exit 1
        fi
      fi
    fi

  else

    # ------
    # lftp

    opt_exclude=""
    while read line; do
      # TODO: allow commentout in the middle of line

      if [ "${line:0:1}" = "/" ]; then
        # /xxx/yyy -> xxx/yyy
        opt_exclude="$opt_exclude -X ${line:1}"
      elif [ "${line:0:1}" != "#" -a "$line" != "" ]; then
        opt_exclude="$opt_exclude -X $line"
      fi
    done<$DEP_IGNORE_FILE

    opt_setting=""
    if [ "$DEP_FTPS" = "no" ]; then
      log "- sync -> via FTP"
      opt_setting="set ftp:ssl-allow off;"
    else
      # TODO: chanto FTPS ni natteruka kakunin
      log "- sync -> via FTPS"
      opt_setting="set ftp:ssl-auth TLS;set ftp:ssl-force true;set ftp:ssl-allow yes;set ftp:ssl-protect-list yes;set ftp:ssl-protect-data yes;set ftp:ssl-protect-fxp yes;"
    fi

    if lftp -u "$DEP_USER,$DEP_PASSWORD" -e "$opt_setting;pwd;mirror -evR --parallel=10 $opt_exclude ./ $DEP_HOST_DIR;exit" "$DEP_HOST"; then
      log "- sync -> done."
    else
      log "- sync -> [ERROR]"
      exit 1
    fi

  fi

  # ----------------
  # After Sync

  if type after_sync 1>/dev/null 2>/dev/null; then
    # detect after_sync method
    echo -n "$log_label- after_sync -> Processing... "
    after_sync
    log " -> Done."
  fi
}

# ----------------
# check parameters

ALL_PARAMS=(COMMAND FTPS PORT HOST USER PASSWORD HOST_DIR INCLUDE_FILE IGNORE_FILE)
NECESSARY_PARAMS=(COMMAND HOST USER HOST_DIR)

for param in ${NECESSARY_PARAMS[@]}; do
  branch_param="DEP_${DRONE_BRANCH^^}_$param"
  remote_param="DEP_REMOTE_$param"
  eval 'val=${'$branch_param'}'
  if [ ! $val ]; then
    eval 'val=${'$remote_param'}'
  fi
  if [ ! $val ]; then
    log "- ERROR -> Not defined necessary parameter: $branch_param or $remote_param"
    exit 1
  fi
done

# ----------------
# casting all parameters
# e.g. DEP_COMMAND=${DEP_MASTER_COMMAND}

for param in ${ALL_PARAMS[@]}; do
  branch_param="DEP_${DRONE_BRANCH^^}_$param"
  remote_param="DEP_REMOTE_$param"
  eval 'val=${'$branch_param'}'
  if [ $val ]; then
    eval "DEP_$param=$val"
  else
    eval 'val=${'$remote_param'}'
    if [ $val ]; then
      eval "DEP_$param=$val"
    fi
  fi
done


# ----------------
# default value

if [ "${DEP_FTPS:-isnil}" = "isnil" ]; then
  DEP_FTPS=yes
fi

# ----------------
# main

if [ "$DEP_COMMAND" = "rsync" -a "${DEP_HOST_DIR:0:1}" != "/" ]; then
  log "- ERROR -> DEP_HOST_DIR must be absolute path: $DEP_HOST_DIR"
  exit 1
fi

# include file

# from web
if [ "${DEP_INCLUDE_FILE:+isexists}" = "isexists" ]; then
  if [ "${DEP_INCLUDE_FILE:0:7}" = "http://" -o "${DEP_INCLUDE_FILE:0:8}" = "https://" ]; then
    log "| Downloading include file..."
    if wget -O .depinc.sh $DEP_INCLUDE_FILE; then
      log "| -> Done."
      DEP_INCLUDE_FILE=$PWD/.depinc.sh
    else
      log "| -> [ERROR]"
      exit 1
    fi
  fi
fi

if [ "${DEP_INCLUDE_FILE:-isnil}" = "isnil" -o ! -f "$DEP_INCLUDE_FILE" ]; then
  log "- include file -> Detect failed..."
else
  log "- include file -> Detect : $DEP_INCLUDE_FILE"
  source "$DEP_INCLUDE_FILE"
fi

do_sync

exit 0
