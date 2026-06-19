#!/bin/bash

# for WordPress website deploy (need SSH)

# ----------------------------------------------------------------------
# メンテナンス表示について
#
# 同期(rsync/lftp)中はファイルが不整合な状態になるため、WordPress 標準の
# `.maintenance` ファイルを使ってデプロイ中だけメンテナンス画面を表示する。
#   - before_sync : 同期開始前にリモートへ .maintenance を設置（メンテ ON）
#   - after_sync  : 同期完了後にリモートから .maintenance を削除（メンテ OFF）
#
# 【必須】.depignore に `.maintenance` を追加すること。
#   rsync は --delete 付きで動作しており、ローカルに無いファイルはリモートから
#   削除される。除外しておかないと設置した .maintenance が同期中に消えてしまう。
#
# 【注意1】WordPress コアは $upgrading から 10 分経過すると自動でメンテを解除する。
#   10 分以上かかるデプロイでは途中で解除される点に留意。
# 【注意2】同期が失敗すると deploy.sh は after_sync を実行せず終了するため、
#   .maintenance が残りメンテ表示が継続する（半端な状態を晒さない利点もあるが、
#   上記 10 分ルールで最終的には自動解除される）。
#
# WP コアの場所に合わせて MAINTENANCE_FILE のパスを調整すること。
# このリポジトリの WordPress 構成ではコアが wp/ 配下にあるため wp/.maintenance。
# ----------------------------------------------------------------------
MAINTENANCE_FILE="$DEP_HOST_DIR/wp/.maintenance"

# リモートでコマンドを実行するヘルパー（ポート指定の有無を吸収）
maintenance_ssh(){
  if [ "${DEP_PORT:+isexists}" = "isexists" ]; then
    ssh "$DEP_USER@$DEP_HOST" -p "$DEP_PORT" "$1"
  else
    ssh "$DEP_USER@$DEP_HOST" "$1"
  fi
}

before_sync(){

  # メンテナンス表示 ON（同期開始前にリモートへ .maintenance を設置）
  maintenance_ssh "printf '%s' '<?php \$upgrading = time(); ?>' > $MAINTENANCE_FILE"

  # extension of backup files which are created before replacement
  ext=".temp_bakup"

  # remove "DEP_XXX_RM "
  find . -name "*.htaccess" -exec sed -i$ext "s|#DEP_REMOTE_RM ||" {} \;
  find . -name "*.htaccess" -exec sed -i$ext "s|#DEP_${GITHUB_REF_NAME^^}_RM ||" {} \;
  find . -name "*robots.txt" -exec sed -i$ext "s|#DEP_REMOTE_RM ||" {} \;
  find . -name "*robots.txt" -exec sed -i$ext "s|#DEP_${GITHUB_REF_NAME^^}_RM ||" {} \;
  find . -name "*.php" -exec sed -i$ext "s|//DEP_REMOTE_RM ||" {} \;
  find . -name "*.php" -exec sed -i$ext "s|//DEP_${GITHUB_REF_NAME^^}_RM ||" {} \;

  # delete backup files
  find . -name "*$ext" -exec rm {} \;

  return
}

after_sync(){
  sh -c "echo '
cd '${DEP_HOST_DIR}'

echo ''
echo --- Set Permissions -------------
find ./ -type d -exec chmod 705 {} \;
find ./ -type f -exec chmod 604 {} \;
find ./ -name .htaccess -exec chmod 604 {} \;
find ./ -name wp-config.php -exec chmod 400 {} \;
echo ---------------------------------
echo ''
echo --- Check Permissions -----------
stat -f \"%N %Mp%Lp\" .htaccess
stat -f \"%N %Mp%Lp\" wp/wp-config.php
stat -f \"%N %Mp%Lp\" wp/wp-content/plugins
stat -f \"%N %Mp%Lp\" wp/wp-content/themes
stat -f \"%N %Mp%Lp\" wp/wp-content/uploads
echo ---------------------------------
echo ''
' > script.sh"
  if [ "${DEP_PORT:+isexists}" = "isexists" ]; then
    ssh $DEP_USER@$DEP_HOST -p $DEP_PORT 'bash -s' < script.sh
  else
    ssh $DEP_USER@$DEP_HOST 'bash -s' < script.sh
  fi
  rm -f script.sh

  # メンテナンス表示 OFF（同期完了・パーミッション設定後に .maintenance を削除）
  maintenance_ssh "rm -f $MAINTENANCE_FILE"
}
