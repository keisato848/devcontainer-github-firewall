#!/usr/bin/env bash
# [What] ファイアウォール構築の統括エントリポイント
# [Who]  devcontainer の postStartCommand がルート権限で呼び出す
# [When] コンテナ起動のたびに毎回実行される (iptables はコンテナ再起動でリセットされるため)
# [Where] .devcontainer/scripts/setup-firewall.sh
# [Why]  dnsmasq・ipset・iptables の設定順序を正しく制御するため、各サブスクリプトを
#        このファイル1か所から順番に呼び出す
# [How]  (1) dnsmasq 起動 → (2) ipset 初期ロード → (3) iptables 適用 → (4) 定期更新デーモン起動

# [Why] -e: コマンド失敗時即終了 / -u: 未定義変数参照を禁止 / -o pipefail: パイプ途中の失敗も検知
# [How] iptables 適用前に ipset 構築が失敗したままロックダウンが進むのを防ぐために必須
set -euo pipefail

# [What] このスクリプト自身が置かれているディレクトリの絶対パスを取得
# [Why]  呼び出し元のカレントディレクトリが何であっても、サブスクリプトを確実に参照できるようにする
# [How]  $0 (スクリプトパス) の dirname を cd して pwd で正規化する
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# [What] iptables の --match-set オプションで参照する ipset の名前
# [Why]  ipset 名はここ1か所だけ定義し、各スクリプトはこの変数を参照することで名前の不一致を防ぐ
IPSET_NAME="github-allow"

# [What] Meta API から CIDR を取得してバックアップ更新する間隔 (秒)
# [Why]  dnsmasq が DNS ベースでリアルタイム追加するため、Meta API 更新は補完役でよく 30分で十分
META_UPDATE_INTERVAL=1800

# [What] このスクリプト群の全ログを書き出すファイルパス
# [Why]  /tmp はコンテナ内で書き込み権限が保証されており、再起動時に自動消去されるため適切
LOG_FILE="/tmp/github-firewall.log"

# [What] タイムスタンプ付きログを標準出力とファイルの両方に書く関数
# [Why]  開発者が postStart ログと /tmp/github-firewall.log の両方で確認できるようにする
# [How]  tee -a でファイルに追記しつつ標準出力にも流す
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# [What] 前回の postStart が残した Meta API 定期更新デーモンを停止する
# [When] コンテナが rebuild せず restart だけされた場合、旧デーモンが生き続けるため
# [Why]  二重起動になると ipset に重複ロックが発生し更新が SKIP され続けるリスクがある
# [How]  PID ファイルが存在し、その PID が実際に生きていれば kill する
if [[ -f /tmp/github-ipset-updater.pid ]]; then
  # [What] 前回書かれた PID 値を読む。ファイル読み取り失敗時は空文字にして続行
  OLD_PID=$(cat /tmp/github-ipset-updater.pid 2>/dev/null || true)
  # [What] PID が空でなく、かつそのプロセスが実際に存在するか確認してから kill する
  # [Why]  存在しない PID を kill すると exit 1 になり set -e でスクリプトが終了するため
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    # [How]  kill 失敗 (競合など) は || true で無視して続行
    kill "$OLD_PID" 2>/dev/null || true
    log "Stopped previous updater (PID $OLD_PID)"
  fi
fi

log "========================================="
log "Setting up GitHub egress firewall"
log "========================================="

# ============================================================
# ステップ 1: dnsmasq セットアップ
# [What] DNS フォワーダを起動し、GitHub ドメインの解決 IP をリアルタイムで ipset に追加する
# [When] ipset・iptables の設定より先に行う
# [Why]  dnsmasq が先に動いていないと、次の Meta API 取得 (curl) や
#        ウォームアップ DNS 解決が失敗する可能性があるため
# ============================================================
log "Setting up dnsmasq..."
# [How] setup-dnsmasq.sh を実行し、標準エラーも含めて LOG_FILE へ tee する
bash "${SCRIPT_DIR}/setup-dnsmasq.sh" 2>&1 | tee -a "$LOG_FILE"

# ============================================================
# ステップ 2: Meta API で CIDR レンジを初期ロード
# [What] api.github.com/meta が返す CIDR ブロックを ipset に一括投入する
# [When] iptables でロックダウンする直前に実施する
# [Why]  dnsmasq は DNS 解決の都度 /32 を追加するが、GitHub は CIDR ブロック単位で
#        IP を運用しているため、事前にレンジ全体を入れておくと解決前の接続にも対応できる
# ============================================================
log "Running initial Meta API ipset update..."
bash "${SCRIPT_DIR}/update-github-ipset.sh" 2>&1 | tee -a "$LOG_FILE"

# [What] ipset に実際に登録されたエントリ数を確認する
# [Why]  ネットワーク障害などで ipset が空のまま OUTPUT DROP になると
#        コンテナ内からどこにも繋げなくなる致命的な状態になるため、最低限のエントリ数を保証する
# [How]  ipset list の出力から、数字で始まる行 (CIDR エントリ) の行数を数える
ENTRY_COUNT=$(ipset list "$IPSET_NAME" | grep -c "^[0-9]" || echo 0)
if [[ "$ENTRY_COUNT" -lt 5 ]]; then
  # [What] エントリが異常に少ない場合はロックダウンを中止してエラー終了する
  # [Why]  5個未満は Meta API 取得の失敗を強く示唆し、この状態でロックダウンすると
  #        開発者がコンテナ内で何もできなくなるため、安全側に倒して終了する
  log "ERROR: ipset has only ${ENTRY_COUNT} entries. Aborting firewall lockdown for safety."
  exit 1
fi

# ============================================================
# ステップ 3: iptables ルール適用
# [What] コンテナの外向きパケットを ipset で制御するルールを設定する
# [When] ipset が確実に構築された後でのみ実行する (ステップ2の安全弁が通過後)
# [Why]  OUTPUT DROP の前にルールを全て揃えないと、設定途中で通信が遮断されてしまう
# [How]  ルールを追加してから最後に P OUTPUT DROP でデフォルトポリシーを変更する
# ============================================================
log "Applying iptables rules..."

# [What] OUTPUT チェーンのデフォルトポリシーを一時的に ACCEPT に戻す
# [When] 既存ルールを flush する直前に実行する
# [Why]  前回実行時の OUTPUT ポリシーが DROP のまま残っていると、今回の再構成中に
#        ルールが一時的に空になった瞬間、スクリプト失敗時に半端な遮断状態が残るため
# [How]  新しい ACCEPT ルールを積み直すまでの短時間だけ fail-open にし、最後に DROP に戻す
iptables -P OUTPUT ACCEPT

# [What] OUTPUT チェーンの既存ルールを全削除してクリーンな状態にする
# [Why]  コンテナ restart 時に前回のルールが残っていると重複 ACCEPT が生じ、
#        意図しない通信を許可してしまう可能性があるため
# [How]  -F はチェーン内のルールを flush する。2>/dev/null はルールが空の場合の警告を抑止
iptables -F OUTPUT 2>/dev/null || true

# ---- ルール 1: ループバック許可 ----
# [What] lo (ループバック) インターフェース宛のパケットを無条件に通過させる
# [Why]  127.0.0.1 宛の通信 (プロセス間 IPC、dnsmasq への localhost:53 など) は
#        外部に出ないため制限する意味がなく、遮断するとコンテナ内部の動作が壊れる
iptables -A OUTPUT -o lo -j ACCEPT

# ---- ルール 2: 確立済みセッション許可 ----
# [What] 既に接続が確立しているパケット (ESTABLISHED) および
#        その接続に付随するパケット (RELATED: FTP データポートなど) を許可する
# [Why]  GitHub の IP が ipset に入る前に確立した接続が IP 変更後も継続できるようにする
#        また、全接続を毎回 ipset ルックアップすることによるパフォーマンス悪化も防ぐ
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# ---- ルール 3: 上流 DNS サーバへの通信許可 ----
# [What] dnsmasq が GitHub Meta API や外部ドメインを解決するために必要な
#        上流 DNS サーバ宛の UDP/TCP 53 番通信を許可する
# [Why]  OUTPUT DROP の後では dnsmasq が外部 DNS に問い合わせできなくなる。
#        全 DNS サーバを許可せず、コンテナが元々使っていた DNS サーバ 1台だけに絞ることで
#        DNS 漏洩リスクを最小化する
# [How]  dnsmasq の設定ファイルから server= の値を読み取ることで、
#        コンテナ環境に依らず正しい上流 DNS を動的に特定する
UPSTREAM_DNS=$(grep '^server=' /etc/dnsmasq.d/github-ipset.conf | head -1 | cut -d= -f2)
if [[ -n "$UPSTREAM_DNS" ]]; then
  iptables -A OUTPUT -d "$UPSTREAM_DNS" -p udp --dport 53 -j ACCEPT
  iptables -A OUTPUT -d "$UPSTREAM_DNS" -p tcp --dport 53 -j ACCEPT
fi

# ---- ルール 4: GitHub ipset 宛の通信許可 ----
# [What] ipset "github-allow" に登録されている IP 宛の TCP 22/80/443 を許可する
# [Why]  SSH (22) は git+ssh プロトコル、80 は HTTP リダイレクト、443 は HTTPS/git+https
#        これら以外のポートを GitHub に対して開ける理由はないため、最小限に絞る
# [How]  -m set --match-set は ipset をカーネル内でハッシュ照合するため O(1) で高速
#        -m multiport --dports はポートリストを1ルールで表現するための拡張モジュール
iptables -A OUTPUT -m set --match-set "$IPSET_NAME" dst \
  -p tcp -m multiport --dports 22,80,443 -j ACCEPT

# ===== 追加の許可ルールはここに書く =====
# [Why] OS パッケージ更新 (apt) や他のレジストリへのアクセスが必要な場合はここに追記する
# 例: apt リポジトリ
#   iptables -A OUTPUT -d <apt-mirror-cidr> -p tcp --dport 443 -j ACCEPT
# 例: npm registry
#   iptables -A OUTPUT -d <npm-registry-cidr> -p tcp --dport 443 -j ACCEPT
# ==========================================

# ---- デフォルトポリシー: OUTPUT DROP ----
# [What] 上記のどのルールにも一致しなかったパケットを全て破棄する
# [When] 必ず全 ACCEPT ルールを追加した後の最後に設定する
# [Why]  -P は チェーンのデフォルトポリシー変更であり、これを先に実行すると
#        ACCEPT ルール追加前の一瞬すべての外向き通信が遮断されてしまう
# [How]  -P OUTPUT DROP はルールではなくポリシーの変更のため、-F でフラッシュしても消えない
iptables -P OUTPUT DROP

# [What] 設定後のルール一覧をログに記録する
# [Why]  どのルールが何番で入ったか後から確認できるようにするため。-n は逆引きなし (高速)
log "iptables OUTPUT rules:"
iptables -L OUTPUT -n --line-numbers 2>&1 | tee -a "$LOG_FILE"

# ============================================================
# ステップ 4: Meta API バックグラウンド更新デーモン起動
# [What] update-github-ipset.sh を 30分ごとに繰り返し実行するループをバックグラウンドで動かす
# [When] iptables ロックダウン完了後に起動する (起動前に実行すると DNS が使えない)
# [Why]  dnsmasq は DNS 解決時にのみ /32 を追加するため、DNS キャッシュがある場合や
#        GitHub が CIDR ブロック単位で新しい IP を追加した場合は Meta API 更新で補完する
# ============================================================
log "Starting Meta API backup updater (interval: ${META_UPDATE_INTERVAL}s)..."
# [What] nohup 付きの別 bash プロセスで無限更新ループをバックグラウンド起動する
# [Why]  postStartCommand は非対話シェルで動くため、disown 前提のジョブ制御は不安定。
#        nohup で SIGHUP を無視させておくほうが VS Code 切断後も確実に継続できる
# [How]  bash -c の引数で interval/script_dir/log_file を渡し、sleep 後に更新を繰り返す
nohup bash -c '
  set -euo pipefail
  interval="$1"
  script_dir="$2"
  log_file="$3"
  while true; do
    sleep "$interval"
    bash "$script_dir/update-github-ipset.sh" >> "$log_file" 2>&1
  done
' bash "$META_UPDATE_INTERVAL" "$SCRIPT_DIR" "$LOG_FILE" >/dev/null 2>&1 &
# [What] バックグラウンドジョブの PID を取得する
# [How]  & の直後の $! は直前に起動したバックグラウンドプロセスの PID
UPDATER_PID=$!
# [What] 次回の postStart で旧デーモンを停止できるよう PID をファイルに保存する
# [Why]  コンテナ restart のたびに重複してデーモンが増殖するのを防ぐため
echo "$UPDATER_PID" > /tmp/github-ipset-updater.pid

log "Background updater started (PID: ${UPDATER_PID})"
log "========================================="
log "Firewall setup complete"
log "  - dnsmasq: リアルタイム ipset 追加 (DNS 解決時)"
log "  - Meta API: CIDR バックアップ更新 (${META_UPDATE_INTERVAL}s 毎)"
log "  - Log: ${LOG_FILE}"
log "========================================="
