#!/usr/bin/env bash
# [What] GitHub Meta API と DNS 解決で収集した CIDR を ipset に原子的に反映する
# [Who]  setup-firewall.sh の初期ロード時および 30分ごとのバックグラウンドデーモンが呼び出す
# [When] (1) ファイアウォール起動時の初期ロード (2) 以降は 30分ごとの定期実行
# [Where] カーネルの ipset テーブルを操作する
# [Why]  dnsmasq は DNS 解決時の /32 しか追加しないが、GitHub は CIDR レンジ単位で IP を運用する。
#        Meta API でレンジ全体を定期投入することで、解決前の IP も事前に許可できる
# [How]  tmp セットを構築してから swap することで、更新中も通信が途切れない原子的な入れ替えを実現する

# [Why] 失敗時の即終了・未定義変数禁止・パイプ失敗検知を有効化
set -euo pipefail

# [What] 実際に iptables が参照する本番 ipset の名前
IPSET_NAME="github-allow"

# [What] 更新中に一時的に使う ipset の名前
# [Why]  本番セットを直接書き換えると更新途中に通信が遮断される可能性があるため、
#        tmp セットで構築してから swap で瞬時に切り替える
IPSET_TMP="${IPSET_NAME}-tmp"

# [What] GitHub が公開する IP レンジ情報の API エンドポイント
# [Why]  GitHub は定期的に IP を変更するが、このエンドポイントで最新のレンジを常に取得できる
META_URL="https://api.github.com/meta"

# [What] 排他ロックに使うファイルディスクリプタ用のファイルパス
# [Why]  定期更新デーモンが 30分ごとに呼ばれる際、前回の更新がまだ実行中の場合に
#        二重実行して ipset の同時操作による競合エラーを防ぐため
LOCK_FILE="/tmp/github-ipset.lock"

# ==================== ユーザ設定 ====================

# [What] Meta API の JSON から取得するサービスのキー名
# [Why]  GitHub の meta API は web/api/git/copilot/hooks/actions/packages など
#        用途別に IP レンジを分けて返す。必要なサービスのキーだけ指定することで
#        不要な IP (例: actions の数千レンジ) を ipset に入れずに済む
META_KEYS=(web api git copilot hooks)

# [What] Meta API の CIDR に加えて DNS 解決でも補完するドメインのリスト
# [Why]  Meta API は完全な一覧ではなく、LFS 等一部サービスの IP が含まれないと
#        GitHub 公式ドキュメントに明記されているため、DNS 解決で補完する
DNS_DOMAINS=(
  github.com
  api.github.com
  codeload.github.com
  objects.githubusercontent.com
  github-releases.githubusercontent.com
  copilot-proxy.githubusercontent.com
  default.exp-tas.com
)

# [What] Meta API や DNS に頼らず常に許可したい固定 CIDR (社内レジストリ等)
# [How]  必要な場合は "192.168.1.0/24" のように追記する
EXTRA_CIDRS=()

# ====================================================

# [What] タイムスタンプ付きログを標準出力に書く関数
# [Why]  setup-firewall.sh 側で >> $LOG_FILE でリダイレクトされるため、
#        ここでは tee せず echo だけにする
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# [What] ファイルディスクリプタ 200 をロックファイルに紐付けて排他ロックを取得する
# [Why]  flock -n (ノンブロッキング) でロック取得を試み、失敗したら別インスタンスが動いていると判断
# [How]  exec 200>file で FD を開き、flock -n 200 でロックを試みる。
#        ロック失敗時は SKIP ログを出して正常終了 (exit 0) する
exec 200>"$LOCK_FILE"
flock -n 200 || { log "SKIP: another update running"; exit 0; }

log "Updating GitHub ipset..."

# [What] GitHub Meta API から最新の IP レンジ情報を JSON で取得する
# [Why]  この JSON が全 CIDR 収集の一次ソース
# [How]  -s: 進捗バー非表示 / -f: HTTP エラー時に失敗扱い / --max-time 15: タイムアウト 15秒
#        取得失敗時は既存 ipset をそのまま維持して exit 0 する (iptables を壊さない)
META_JSON=$(curl -sf --max-time 15 "$META_URL" 2>/dev/null) || {
  log "WARN: Meta API fetch failed — keeping existing ipset"
  exit 0
}

# [What] 収集した全 CIDR を格納する配列
CIDRS=()

# [What] META_KEYS で指定したサービスごとに JSON から IPv4 CIDR を抽出する
# [How]  jq -r で raw 文字列出力し、.${key}[]? で各サービスの IP リストを展開する
#        // empty はキーが存在しない場合に null ではなく空を返すため、エラーを防ぐ
for key in "${META_KEYS[@]}"; do
  while IFS= read -r cidr; do
    # [Why] IPv6 アドレスはコロンを含むため除外する (iptables の IPv4 ルールとは別に扱う)
    [[ "$cidr" =~ : ]] && continue
    # [Why] jq が空行を返す場合があるため空文字も除外する
    [[ -z "$cidr" ]] && continue
    CIDRS+=("$cidr")
  done < <(echo "$META_JSON" | jq -r ".${key}[]? // empty" 2>/dev/null)
done

# [What] DNS 解決で Meta API に載っていない IP を補完する
# [How]  dig +short で A レコードだけを取得する。+time=3 はタイムアウト、+tries=1 はリトライなし
#        取得失敗 (|| true) は無視して他のドメインを続行する
for domain in "${DNS_DOMAINS[@]}"; do
  while IFS= read -r ip; do
    # [Why] dig は CNAME チェーンも返すことがあるため、数値で始まる行 (IP) だけを取り込む
    [[ -n "$ip" && "$ip" =~ ^[0-9]+\. ]] && CIDRS+=("${ip}/32")
  done < <(dig +short +time=3 +tries=1 A "$domain" 2>/dev/null || true)
done

# [What] ユーザが手動追加した固定 CIDR を末尾に追加する
for cidr in "${EXTRA_CIDRS[@]}"; do
  CIDRS+=("$cidr")
done

# [What] 重複する CIDR を除去してソートする
# [Why]  Meta API と DNS 解決の両方で同じ /32 が得られることがあり、
#        重複 CIDR を ipset に add しようとするとエラーになる (-exist で回避もできるが整理しておく)
# [How]  printf で1行1エントリに並べ、sort -u で重複除去しながらソート、readarray で配列に戻す
readarray -t CIDRS < <(printf '%s\n' "${CIDRS[@]}" | sort -u)

# [What] 収集した CIDR が極端に少ない場合は異常とみなして更新を中止する
# [Why]  ネットワーク断絶や API 仕様変更でゼロに近い件数になった場合に
#        本番 ipset をほぼ空の tmp セットで swap してしまうのを防ぐ安全弁
if [[ ${#CIDRS[@]} -lt 5 ]]; then
  log "WARN: Only ${#CIDRS[@]} CIDRs — likely fetch error. Aborting."
  exit 0
fi

log "Collected ${#CIDRS[@]} unique CIDRs"

# ---- 原子的 ipset 更新 ----
# [What] 一時セットを作成する。既に存在する場合はスキップ (-exist)
# [Why]  前回の実行が途中で失敗して tmp セットが残っていても再実行できるようにする
ipset create "$IPSET_TMP" hash:net maxelem 65536 -exist
# [What] 一時セットを空にする
# [Why]  -exist で使い回す場合、前回の残留エントリを消さないと古い IP が混入する
ipset flush "$IPSET_TMP"

# [What] 収集した全 CIDR を一時セットへ投入する
# [Why]  本番セットではなく tmp セットに入れることで、追加中も本番セットは変わらず通信が継続できる
fail_count=0
for cidr in "${CIDRS[@]}"; do
  # [How]  -exist: 既にセットにある CIDR は成功扱い (重複エラーを無視)
  #        2>/dev/null: 不正な CIDR 形式などのエラーを抑止
  #        || ((fail_count++)) || true: 失敗をカウントしつつ set -e で終了させない
  ipset add "$IPSET_TMP" "$cidr" -exist 2>/dev/null || ((fail_count++)) || true
done
[[ $fail_count -gt 0 ]] && log "WARN: ${fail_count} entries failed to add"

# [What] 本番セットが存在しない場合に備えて作成しておく (初回実行時)
ipset create "$IPSET_NAME" hash:net maxelem 65536 -exist

# [What] tmp セットと本番セットを原子的に入れ替える
# [Why]  swap はカーネル内で単一の操作として実行されるため、
#        「古いセット削除 → 新しいセット追加」のような2ステップと違い、
#        切り替え瞬間に通信が途切れることがない
# [How]  ipset swap A B は A と B の中身を交換する。swap 後の IPSET_TMP (旧本番) を削除する
ipset swap "$IPSET_TMP" "$IPSET_NAME"
ipset destroy "$IPSET_TMP" 2>/dev/null || true

log "OK: ipset '${IPSET_NAME}' updated (${#CIDRS[@]} entries)"
