#!/bin/bash
# このMacのキーチェーンにある「Apple Development」署名証明書から Team ID を読み取って出力する。
# ビルド時に `DEVELOPMENT_TEAM="$(bash scripts/detect-team.sh)"` として渡すことで、
# project.yml を書き換えずに、誰のApple IDでもビルドできるようにする。
#
# 証明書名の括弧内(例: "Apple Development: foo@example.com (2DV3KFXZ93)")は Team ID ではないので使わない。
# Team ID は証明書の OU(organizationalUnitName)に入っている。
#
# 終了コード: 0 = Team IDが1つに決まった / 1 = 証明書が無い / 2 = 複数チームの証明書があり選べない
set -euo pipefail

teams=$(
  security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Apple Development: .*\)"$/\1/p' \
    | while IFS= read -r name; do
        security find-certificate -c "$name" -p \
          | /usr/bin/openssl x509 -noout -subject -nameopt multiline \
          | awk -F' = ' '/organizationalUnitName/{print $2}'
      done \
    | sort -u
)

count=$(printf '%s' "$teams" | grep -c . || true)

if [ "$count" -eq 0 ]; then
  echo "Apple Development 証明書が見つかりません。Xcode → Settings → Accounts でApple IDにサインインしてください。" >&2
  exit 1
fi
if [ "$count" -gt 1 ]; then
  echo "複数のチームの証明書があります。使うTeam IDを指定してください:" >&2
  printf '%s\n' "$teams" >&2
  exit 2
fi
printf '%s\n' "$teams"
