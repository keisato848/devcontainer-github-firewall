# GitHub Firewall Dev Container

GitHub API、git clone / push、GitHub Copilot などへの通信だけを Linux コンテナから許可し、それ以外の外向き通信を iptables で遮断するための Dev Container 構成です。

この構成は、GitHub の IP が動的に変わるために固定 IP ベースの許可制御が破綻しやすい、という問題に対して、proxy を立てず `.devcontainer` のみで追従できる形を狙っています。

## 何を解決するか

典型的な問題は次の通りです。

- コンテナの `OUTPUT` を `DROP` にして、許可したい宛先だけ `ACCEPT` したい
- ただし `api.github.com` や `github.com` の IP は固定ではなく変わる
- `postStartCommand` で 1 回だけ名前解決して iptables を張ると、後から IP が変わった時点で通信できなくなる
- それでも proxy は使えず、Dev Container の中だけで完結させたい

このリポジトリは、その制約のまま次の 2 系統で追従します。

1. `dnsmasq --ipset`
DNS 応答で返ってきた GitHub 系 IP を、その場で即座に ipset に入れます。新しい IP が使われ始めても、最初の DNS 解決で追従できます。

2. GitHub Meta API バックアップ更新
`https://api.github.com/meta` から GitHub 公開 CIDR を定期取得し、ipset を原子的に差し替えます。DNS 解決前の新しい CIDR や、周辺サービスの補完を担います。

## アーキテクチャ

通信制御の流れは次の通りです。

```text
アプリ (git / curl / Copilot / npm など)
  -> /etc/resolv.conf
  -> 127.0.0.1 の dnsmasq
  -> 上流 DNS に問い合わせ
  -> 応答 IP を ipset github-allow に自動追加
  -> アプリがその IP に TCP 接続
  -> iptables が ipset を参照して 22/80/443 のみ許可
```

3 つのスクリプトが役割分担します。

- `.devcontainer/scripts/setup-dnsmasq.sh`
  ローカル dnsmasq を起動し、GitHub 関連ドメインの DNS 応答を ipset に自動登録します。
- `.devcontainer/scripts/update-github-ipset.sh`
  Meta API と DNS 補完を使って ipset を再構築し、`ipset swap` で原子的に切り替えます。
- `.devcontainer/scripts/setup-firewall.sh`
  起動順序を制御し、iptables ルールを適用し、定期更新デーモンを起動します。

## ディレクトリ構成

```text
.
├── README.md
└── .devcontainer
    ├── devcontainer.json
    └── scripts
        ├── setup-dnsmasq.sh
        ├── setup-firewall.sh
        └── update-github-ipset.sh
```

## 起動時に何が起きるか

Dev Container 起動時の処理順序は次の通りです。

1. `onCreateCommand`
   必要パッケージを入れます。
   `ipset`, `iptables`, `jq`, `dnsutils`, `curl`, `dnsmasq`

2. `postStartCommand`
   `.devcontainer/scripts/setup-firewall.sh` を root 権限で実行します。

3. `setup-dnsmasq.sh`
   既存の `/etc/resolv.conf` から上流 DNS を取得し、dnsmasq を `127.0.0.1:53` で起動します。

4. `update-github-ipset.sh`
   Meta API と DNS から GitHub 宛ての CIDR / IP を収集し、`github-allow` を更新します。

5. `setup-firewall.sh`
   iptables `OUTPUT` を組み直し、最終的にデフォルトポリシーを `DROP` にします。

6. バックグラウンド更新
   30 分ごとに Meta API バックアップ更新を継続します。

## 許可している通信

初期状態で許可しているのは次だけです。

- ループバック通信
- 既存の確立済み通信
- 上流 DNS サーバへの 53/udp と 53/tcp
- ipset `github-allow` に含まれる宛先への `tcp/22`, `tcp/80`, `tcp/443`

つまり、GitHub 宛て以外の一般的な外向き通信は遮断されます。

## 対象にしている GitHub 系ドメイン

dnsmasq 側で主に次のドメイン群を監視します。

- `github.com`
- `githubusercontent.com`
- `githubcopilot.com`
- `githubassets.com`
- `github.dev`
- `ghcr.io`
- `github.io`
- `exp-tas.com`
- `githubapp.com`
- `pkg.github.com`

補足です。

- `/github.com/` のような設定はサブドメインも含みます
- Copilot 系の実通信で現れやすい `copilot-proxy.githubusercontent.com` も `githubusercontent.com` 側で拾います
- `default.exp-tas.com` は Copilot の実験系到達先として補完対象に含めています

## Meta API で取得しているサービス

`update-github-ipset.sh` では次のキーを対象にしています。

- `web`
- `api`
- `git`
- `copilot`
- `hooks`

意図的に含めていないものもあります。

- `actions`
- `packages`

これは GitHub Actions や Packages の IP 範囲が広く、不要なら許可面積を増やしたくないためです。必要なら `META_KEYS` に追加してください。

## セキュリティ特性

この構成は「完全に GitHub だけを厳密保証する」ものではなく、「GitHub 系通信だけを最小限で許可したい」という実務上のバランスを取る設計です。

強みは次です。

- proxy 不要
- Dev Container 内だけで完結
- DNS 解決時に即追従できる
- `ipset swap` により更新中の通信断を抑えられる
- GitHub 以外は原則 `OUTPUT DROP`

一方で限界もあります。

- GitHub 公式も IP allowlist の恒久運用は推奨していません
- DNS と Meta API に依存するため、GitHub 側の仕様変更には追従調整が必要です
- 現状は IPv4 前提です。IPv6 は iptables / ip6tables を別途設計してください
- `/etc/resolv.conf` を書き換えるため、社内 DNS 特有の search domain が必要な環境では追加調整が要ります
- apt, npm, pip など GitHub 以外のレジストリは初期状態では通りません

## カスタマイズ方法

### 1. GitHub 以外も許可したい場合

`.devcontainer/scripts/setup-firewall.sh` の追加ルール欄に明示的に追記します。

例:

```bash
iptables -A OUTPUT -d <registry-cidr> -p tcp --dport 443 -j ACCEPT
```

### 2. 常に許可したい固定 CIDR がある場合

`.devcontainer/scripts/update-github-ipset.sh` の `EXTRA_CIDRS` に追加します。

```bash
EXTRA_CIDRS=(
  "192.0.2.0/24"
)
```

### 3. Actions / Packages も含めたい場合

`.devcontainer/scripts/update-github-ipset.sh` の `META_KEYS` を拡張します。

```bash
META_KEYS=(web api git copilot hooks actions packages)
```

### 4. 定期更新間隔を変えたい場合

`.devcontainer/scripts/setup-firewall.sh` の `META_UPDATE_INTERVAL` を変更します。

## 動作確認の観点

Dev Container 起動後は、コンテナ内で次の観点を確認します。

```bash
ipset list github-allow
iptables -L OUTPUT -n --line-numbers
dig +short github.com
curl -I https://api.github.com
git ls-remote https://github.com/<owner>/<repo>.git
```

必要ならログも確認します。

```bash
tail -f /tmp/github-firewall.log
```

## 必須条件

- Docker が使えること
- Dev Containers 拡張が使えること
- コンテナに `NET_ADMIN` と `NET_BIND_SERVICE` を付与できること
- コンテナ内で root 権限または `sudo` が使えること

## この README を読むべき人

次のような要件の人に向いています。

- 開発コンテナからの外向き通信を最小化したい
- ただし GitHub と Copilot は使いたい
- proxy は導入できない
- 固定 IP ベースの allowlist 破綻を避けたい

逆に、全ての外部 SaaS へ柔軟に接続する汎用開発環境には向きません。

## 補足

スクリプトには 5W1H ベースの詳細コメントを入れてあります。ロジックの変更時は、コードだけでなくコメントも一緒に更新してください。
