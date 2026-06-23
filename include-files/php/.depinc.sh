#!/bin/bash

# for PHP website deploy

# .htaccess / robots.txt / *.php に埋め込んだ環境別マーカーを除去する。
#   #DEP_REMOTE_RM  / #DEP_<BRANCH>_RM   … apache(.htaccess) / robots.txt 用
#   //DEP_REMOTE_RM / //DEP_<BRANCH>_RM  … php 用
# REMOTE は全環境、<BRANCH> は対象ブランチ（GITHUB_REF_NAME を大文字化）でのみ除去。
#
# 【mtime を保つ理由】
# sed -i は置換が無くてもファイルを書き直して mtime を更新する。全 .php を無条件に
# sed -i すると、git-restore-mtime 等で安定させた mtime が毎回更新され、lftp mirror
# が変更の無いファイルまで再送してしまう。そこで
#   1) grep で実際にマーカーを含むファイルだけを対象にし、
#   2) sed の前後で mtime を保存・復元する。
# これにより未変更ファイルの再送を防ぎ、差分転送を効かせる。

# 指定ファイルに sed をかけるが、mtime は元の値に復元する（GNU coreutils 前提）
# usage: dep_sed_keep_mtime <file> <sed-expr> [<sed-expr> ...]
dep_sed_keep_mtime(){
  local f="$1"; shift
  local ts; ts="$(stat -c %Y "$f")"
  local args=(); local e
  for e in "$@"; do args+=(-e "$e"); done
  sed -i "${args[@]}" "$f"
  touch -d "@$ts" "$f"
}

before_sync(){
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
