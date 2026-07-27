#!/bin/bash

# for WordPress website deploy（rsync(SSH) / lftp(FTP) 両対応）
#
# 機能:
#  - デプロイ前にサーバ側の WP コアのバージョンを確認し、サーバの方が新しければ中断する
#    （サーバ側で入った自動更新を mirror --delete で巻き戻さないため）。
#  - デプロイ中だけ WordPress 標準の .maintenance を設置してメンテナンス画面を表示
#    （同期中の不整合をユーザに見せない）。rsync(SSH) でも lftp(FTP) でも動作する。
#  - .htaccess / robots.txt / *.php の #DEP_*_RM / //DEP_*_RM マーカーを除去（後述の
#    通り mtime を保存して差分転送を維持）。
#  - rsync の場合のみ、同期後にパーミッションを設定する（FTP では実施不可のため skip）。
#
# 必要に応じて調整する環境変数:
#   DEP_WP_DIR                  WP コアのディレクトリ（HOST_DIR からの相対）。既定 "wp"
#   DEP_WP_SKIP_VERSION_CHECK   1 にするとコアのバージョン照合を飛ばす（意図的なダウン
#       グレード等、巻き戻しを承知で配信したいときの緊急避難用）
#   DEP_MAINTENANCE_MAX_MINUTES メンテ表示を維持する最大時間（分）。既定 60
#       .maintenance の $upgrading を「現在時刻 + この分数」に設定する。WordPress は
#       $upgrading から 10 分でメンテを自動解除するため、time() のままだと長時間デプロイ
#       の途中で解除されてしまう。未来時刻にすることで解除を防ぎつつ、万一 teardown が
#       走らなかった場合でもこの時間で自動復帰する（永久ロック防止）。
#
# 【必須】.depignore に `.maintenance` を追加すること。
#   mirror は --delete 付きで動作するため、除外しないと設置した .maintenance が同期中に
#   削除されてしまう。
#
# メンテ ON/OFF のタイミング:
#   before_sync : 残骸を掃除 → .maintenance を設置（メンテ ON）
#   on_teardown : .maintenance を削除（メンテ OFF）。deploy.sh の EXIT trap から呼ばれ、
#                 同期の成功・失敗・中断いずれでも必ず実行される。

DEP_WP_DIR="${DEP_WP_DIR:-wp}"
_dep_maint_file="$DEP_HOST_DIR/$DEP_WP_DIR/.maintenance"

# lftp をワンショット実行（FTPS 設定を吸収）
_dep_lftp(){
  local opt="set ftp:ssl-allow off;"
  if [ "$DEP_FTPS" != "no" ]; then
    opt="set ftp:ssl-auth TLS;set ftp:ssl-force true;set ftp:ssl-protect-data yes;"
  fi
  lftp -u "$DEP_USER,$DEP_PASSWORD" -e "$opt $1;bye" "$DEP_HOST"
}

# ssh をワンショット実行（ポート指定を吸収）
_dep_ssh(){
  if [ "${DEP_PORT:+x}" = "x" ]; then
    ssh "$DEP_USER@$DEP_HOST" -p "$DEP_PORT" "$1"
  else
    ssh "$DEP_USER@$DEP_HOST" "$1"
  fi
}

maintenance_on(){
  local ts=$(( $(date +%s) + ${DEP_MAINTENANCE_MAX_MINUTES:-60} * 60 ))
  local content="<?php \$upgrading = $ts; ?>"
  if [ "$DEP_COMMAND" = "lftp" ]; then
    local tmp; tmp="$(mktemp)"
    printf '%s' "$content" > "$tmp"
    _dep_lftp "put \"$tmp\" -o \"$_dep_maint_file\""
    rm -f "$tmp"
  else
    _dep_ssh "printf '%s' '$content' > \"$_dep_maint_file\""
  fi
}

maintenance_off(){
  if [ "$DEP_COMMAND" = "lftp" ]; then
    _dep_lftp "rm -f \"$_dep_maint_file\"" 2>/dev/null || true
  else
    _dep_ssh "rm -f \"$_dep_maint_file\"" 2>/dev/null || true
  fi
}

# 指定ファイルに sed をかけるが mtime は元の値に復元する（GNU coreutils 前提）
# sed -i は置換が無くてもファイルを書き直して mtime を更新するため、未変更ファイルが
# mirror で再送されてしまう。grep で対象を絞り、mtime を保存して差分転送を維持する。
dep_sed_keep_mtime(){
  local f="$1"; shift
  local t; t="$(stat -c %Y "$f")"
  local args=(); local e
  for e in "$@"; do args+=(-e "$e"); done
  sed -i "${args[@]}" "$f"
  touch -d "@$t" "$f"
}

# サーバ側の WP コアのバージョンを確認し、サーバの方が新しければデプロイを中断する。
#
# WP コアを git 管理して mirror（--delete 付き）で配信する構成では、サーバ側で自動更新が
# 走るとデプロイのたびにコアが古いバージョンへ巻き戻る。巻き戻り＝セキュリティ修正の消失
# なので、検知したらデプロイを止めて手元での更新を促す。
# これにより wp-config.php で WP_AUTO_UPDATE_CORE を有効にしたまま運用できる。
#
# 中断は exit で行う。deploy.sh は before_sync の戻り値を見ないため return 1 では止まらない。
# 呼び出しはメンテ ON より前に置くこと（中断時にメンテ画面を残さないため）。
check_wp_core_version(){
  [ "${DEP_WP_SKIP_VERSION_CHECK:-}" = "1" ] && return 0

  local local_file="./$DEP_WP_DIR/wp-includes/version.php"
  # コアを含まない構成（テーマのみのリポジトリ等）では何もしない
  [ -f "$local_file" ] || return 0

  local remote_file="$DEP_HOST_DIR/$DEP_WP_DIR/wp-includes/version.php"
  local remote_raw
  if [ "$DEP_COMMAND" = "lftp" ]; then
    remote_raw="$(_dep_lftp "cat \"$remote_file\"" 2>/dev/null)"
  else
    remote_raw="$(_dep_ssh "cat '$remote_file'" 2>/dev/null)"
  fi

  local local_ver remote_ver
  local_ver="$(grep -m1 '^\$wp_version = ' "$local_file" | cut -d"'" -f2)"
  remote_ver="$(printf '%s\n' "$remote_raw" | grep -m1 '^\$wp_version = ' | cut -d"'" -f2)"

  # 初回デプロイ等でサーバ側に WP が無い場合や、取得に失敗した場合は素通りさせる
  [ -n "$remote_ver" ] || return 0
  [ "$local_ver" = "$remote_ver" ] && return 0

  # リポジトリの方が新しい = これから更新を配信する（正常な更新デプロイ）
  [ "$(printf '%s\n%s\n' "$local_ver" "$remote_ver" | sort -V | tail -1)" = "$local_ver" ] && return 0

  # サーバ側の方が新しい = サーバで自動更新が走った
  cat >&2 <<EOF

${log_label}==================================================================
${log_label} デプロイを中断しました
${log_label} サーバ側の WordPress の方が新しいため、このまま配信すると巻き戻ります
${log_label}
${log_label}   サーバ側   : $remote_ver
${log_label}   リポジトリ : $local_ver
${log_label}
${log_label} サーバ側で WordPress の自動更新が実行されています。
${log_label} このまま同期するとコアが $local_ver に戻り、$remote_ver で入った
${log_label} セキュリティ修正が失われます。
${log_label}
${log_label} 手元で下記を実行し、コミットして push し直してください。
${log_label}
${log_label}   wp core update --version=$remote_ver --force
${log_label}
${log_label} （wp-cli が無い場合は WordPress $remote_ver を公式サイトから取得し、
${log_label}   $DEP_WP_DIR/ 配下を差し替える）
${log_label}
${log_label} 意図的に巻き戻す場合のみ DEP_WP_SKIP_VERSION_CHECK=1 を設定する。
${log_label}==================================================================

EOF
  exit 1
}

before_sync(){
  # サーバ側で自動更新が入っていないか確認する。メンテ ON より前に行うこと
  check_wp_core_version

  # 直前の失敗等で残った .maintenance を掃除してからメンテ ON
  maintenance_off
  maintenance_on

  local branch="${GITHUB_REF_NAME^^}"

  # .htaccess / robots.txt（# プレフィックス）
  while IFS= read -r -d '' f; do
    dep_sed_keep_mtime "$f" "s|#DEP_REMOTE_RM ||" "s|#DEP_${branch}_RM ||"
  done < <(grep -rlZ --exclude-dir=.git --include='*.htaccess' --include='*robots.txt' \
             -e "#DEP_REMOTE_RM " -e "#DEP_${branch}_RM " . 2>/dev/null)

  # *.php（// プレフィックス）
  while IFS= read -r -d '' f; do
    dep_sed_keep_mtime "$f" "s|//DEP_REMOTE_RM ||" "s|//DEP_${branch}_RM ||"
  done < <(grep -rlZ --exclude-dir=.git --include='*.php' \
             -e "//DEP_REMOTE_RM " -e "//DEP_${branch}_RM " . 2>/dev/null)

  return 0
}

after_sync(){
  # パーミッション設定は SSH 前提。lftp(FTP) では実施できないため skip。
  [ "$DEP_COMMAND" = "lftp" ] && return 0

  _dep_ssh "
    cd '$DEP_HOST_DIR'
    echo '--- Set Permissions -------------'
    find ./ -type d -exec chmod 705 {} \;
    find ./ -type f -exec chmod 604 {} \;
    find ./ -name .htaccess -exec chmod 604 {} \;
    find ./ -name wp-config.php -exec chmod 400 {} \;
    echo '---------------------------------'
  "
}

# deploy.sh の EXIT trap から呼ばれ、成功・失敗・中断いずれでもメンテを解除する
on_teardown(){
  maintenance_off
}
