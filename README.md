# Element X × Conduit × Tailscale — 自宅完結チャット・レシピ

**matrix.org も、公開ポートも、クラウドアカウントも使わない。** スマホと自宅サーバー
の間だけで完結する Matrix チャットに、ローカル LLM の AI bot を足す手順。
すべて実機（Mac mini + iPhone + Element X）で動作確認済みの構成です。

```
iPhone (Element X) ──HTTPS──▶ tailscale serve (443)
                                 ├── /_matrix     ─▶ 127.0.0.1:8008   Conduit (Docker)
                                 └── /.well-known ─▶ 127.0.0.1:9111   静的JSON
自宅サーバー内:
  Conduit ── RocksDB (./db/)
  bot (Hermes Agent gateway) ── 127.0.0.1:8008 ── OpenAI互換エンドポイント(ローカルLLM)
```

得られるもの:

- iPhone と自宅サーバー間のプライベートチャット（Element X そのまま使える）
- AI bot（OpenAI 互換なら何でも・ローカル LLM 推奨）
- スマホへの通知（仕組みの注意点は「通知とプライバシー」参照）
- 外部依存は Tailscale（無料枠）と Element X アプリのみ。Message チャンネルの
  メッセージ本文・媒体はすべて自宅のディスク上

前提:

- macOS 機（Mac mini 推奨・Apple Silicon で検証）または Linux box
- Docker（Mac なら colima を推奨）
- Tailscale（MagicDNS 有効）+ iPhone に Tailscale アプリと Element X
- 作業時間: 30〜60 分（bot なし構成なら 20 分）

---

## 0. 設計判断を先に（後から変えられないもの）

**`server_name` は一度決めたら永遠です。** ユーザー ID が `@you:server_name` に
組み込まれ、後から変えると全アカウント・部屋・履歴が無効になります。
Tailscale を使うなら、サーバーの tailnet ホスト名（例: `matrix.example.ts.net`）
をそのまま server_name にするのが簡単です。

> 実運用の教訓: うちの環境では歴史的経緯で server_name が接続ホスト名と別名に
> なっています（federation を切っているので名前は単なるラベルとして動作する）。
> ただし新規に構築するなら**最初から同じ名前に揃える**のが間違いありません。

federation はオフ（`allow_federation = false`）。外部サーバーとつながらない
代わりに、攻撃面がほぼゼロになります。

---

## 1. Homeserver: Conduit を Docker で動かす

[Conduit](https://conduit.rs) は軽量な Matrix homeserver（Rust・単一バイナリ）。
RocksDB のデータディレクトリ 1 つで完結し、バックアップもディレクトリごと
コピーするだけです。

**バージョンは 0.10.15（執筆時最新）以上を使ってください。** Element X は
Simplified Sliding Sync（MSC4186）を必須とし、Conduit では 0.10.0 以降が
対応しています。さらに 0.10.13/0.10.14 で認証バイパス・アカウント乗っ取りの
重大脆弱性が修正されているため、**0.10.11 未満は絶対に使わない**こと
（CVE-2025-68667・CVE-2026-24471。Conduit のリリースは遅いので、CVE 情報は
自分で追うこと）。

```bash
git clone https://github.com/<you>/elementx-local-recipe.git
cd elementx-local-recipe/scripts
cp conduit.toml.example conduit.toml
# conduit.toml を編集:
#   server_name         ← 永久に使う名前（上の注意を読むこと）
#   registration_token  ← 長いランダム文字列（例: openssl rand -hex 16）
./run-matrix.sh
curl -s http://127.0.0.1:8008/_matrix/client/versions   # JSONが返ればOK
```

Mac の場合、Docker は colima を推奨します。**コンテナから外へ出る DNS** を
設定しておくこと（通知の push gateway への接続に必要。デフォルトのままで
名前解決が死んでいると「通知だけ届かない」になります）:

```bash
brew install colima docker
colima start --vm-type vz --cpu 2 --memory 2 --disk 20 --mount-type virtiofs \
  --dns 1.1.1.1 --dns 8.8.8.8
```

Conduit は `127.0.0.1:8008` でだけ listen します。TLS は次の tailscale serve
が前段で受け持つので、サーバー自身の証明書は不要です。

---

## 2. Discovery: `/.well-known/matrix/client`

Element X は**ログイン画面に入力したホスト名**に対して
`GET /.well-known/matrix/client` を取りに行き、そこに書かれた `base_url` を
使います。このファイルを配るのが discovery の正本です。

```bash
# 静的ファイルを用意（serve-wellknown.py が自動生成もします）
mkdir -p wellknown-root/matrix
echo '{"m.homeserver":{"base_url":"https://matrix.example.ts.net"}}' \
  > wellknown-root/matrix/client

# 127.0.0.1:9111 で配る（--homeserver-url はあなたのホスト名に）
python3 scripts/serve-wellknown.py --root wellknown-root --port 9111 \
  --homeserver-url https://matrix.example.ts.net
```

常駐させるなら launchd（Mac）や systemd（Linux）に登録します。中身はただの
静的 JSON なので、`python3 -m http.server 9111 --directory wellknown-root
--bind 127.0.0.1` でも同じです。

> 実測＋ソース確認メモ: Conduit 本家（v0.10.15）の well-known 設定は
> `[global.well_known]` **サブテーブル**で書くのが正解です。conduwuit /
> continuwuity 系フォークの設定で見かけるフラットな `well_known_client` キーは
> **本家では黙って無視されます**（未定義キーは catchall で捨てられ、警告も
> 出ません）。無視された場合、Conduit 自身の `8008/.well-known` は
> `server_name` 由来のデフォルト URL を返します。またログイン応答（`POST
> /login`）に `well_known` は含まれないため、**discovery の正本は「入力
> ホスト名の `/.well-known`」一箇所だけ**。ここを正しく配れば、Conduit 自身の
> well-known がずれていても影響しません。なお well-known を配るのは別の
> Web サーバーでよく（spec 明記）、CORS ヘッダの付与が SHOULD です
> （`python3 -m http.server` は CORS ヘッダを返さないので、厳密にやるなら
> `serve-wellknown.py` を使ってください）。

---

## 3. tailscale serve で外に出す（ポート開放なし）

TLS 終端と公開は tailscale serve に任せます。ルーターのポート開放は不要で、
サーバーは tailnet 内からしか見えません。

```bash
tailscale serve --bg --https=443 --set-path=/_matrix http://127.0.0.1:8008/_matrix
sleep 2
tailscale serve --bg --https=443 --set-path=/.well-known http://127.0.0.1:9111/.well-known
sleep 2
tailscale serve status   # 2行とも乗っていることを必ず確認
```

または `scripts/serve-paths.sh` を実行してください（確認付き）。

**ACL の注意**: tailnet ポリシーで、スマホからこのサーバーへの
`tcp:443` を許可してください（Tailscale のデフォルトは拒否です）。
未許可だとスマホからだけタイムアウトします（サーバー自身からは見えるので
気づきにくい。サーバー自身からの `curl https://自分の名前/...` も
誤検出が出ることがあるので、確認は別の tailnet 端末から行うのが確実です）。

---

## 4. アカウント作成

**Element X はログインしかできません**（Matrix の新アカウント作成 UI は
管理サービス搭載サーバー向け）。トークン制の登録を API から行います:

```bash
export REGISTRATION_TOKEN='conduwuit.toml に入れたトークン'
./scripts/create-account.sh https://matrix.example.ts.net you
# パスワードを聞かれる → Element X で同じ組合せでログインする
```

やっていることは 1 リクエストだけです:

```
POST /_matrix/client/v3/register
{"username": "you", "password": "...", "inhibit_login": true,
 "auth": {"type": "m.login.registration_token", "token": "..."}}
```

---

## 5. Element X でログイン（iPhone）

1. iPhone に Tailscale アプリ（接続 ON）と Element X を入れる
2. Element X のサインイン画面で「サインイン方法を手動で選ぶ（Sign in
   manually）→ アカウントプロバイダを変更 → その他（Other）」から
   `https://matrix.example.ts.net` を入力
   （QR コードログインは Matrix Authentication Service 前提なので
   Conduit では使えません。ユーザー名＋パスワードでログインします。
   Element X はまず OIDC 認証メタデータを確認し、無ければパスワード
   ログインへフォールバックするため、MAS 無しでも素直に通ります）
3. 手順 4 で作ったユーザー名とパスワードでログイン
4. 部屋を作る → bot を招待（手順 6 の後で）
5. ログイン直後にリカバリーキーやデバイス確認の案内が出ますが、暗号化部屋を
   使わないならすべてスキップして構いません

**端末側の注意（iPhone）**: Tailscale の MagicDNS を有効にすること。
iCloud プライベートリレー／Wi-Fi の「IP アドレストラッキングを制限」は
`*.ts.net` への接続を断続的に壊す（既知の問題）ので、この Wi-Fi では
オフにする。常駐 VPN やプライバシー系ブラウザ拡張も `*.ts.net` を
潰すことがあるので切るか除外する。

**部屋は暗号化しないでください**（このレシピの bot は E2EE 非対応・理由は
「落とし穴」参照）。Element X は平文部屋も普通に使えます。

---

## 6. AI bot を足す（Hermes Agent）

チャット部屋に住む bot は [Hermes Agent](https://hermes-agent.nousresearch.com)
（Nous Research）の gateway 機能で実装しています。bot の頭脳は OpenAI 互換
エンドポイントなら何でもよく、ローカル LLM サーバー（LiteLLM 経由など）を
指させて完全オフライン運用も可能です。

```bash
# 1) bot 用アカウントを作る
REGISTRATION_TOKEN=... ./scripts/create-account.sh https://matrix.example.ts.net bot

# 2) bot 用の HOME を用意して環境変数を書く
mkdir -p ~/matrix-bot-home
cp scripts/matrix.env.example ~/matrix-bot-home/.env
chmod 600 ~/matrix-bot-home/.env
#   MATRIX_HOMESERVER=http://127.0.0.1:8008
#   MATRIX_USER_ID=@bot:matrix.example.ts.net
#   MATRIX_PASSWORD=...
#   MATRIX_DEVICE_ID=botdev01          ← 固定推奨（ghost device 防止）
#   MATRIX_ALLOWED_USERS=@you:matrix.example.ts.net
#   MATRIX_HOME_ROOM=!…:…              ← bot のホーム部屋
#   MATRIX_E2EE_MODE=optional
#   OPENAI_BASE_URL / OPENAI_API_KEY   ← 頭脳（OpenAI互換なら何でも）

# 3) launchd に登録（plist テンプレートを自分のパスに合わせて編集）
cp scripts/com.example.matrix-bot.plist.example \
   ~/Library/LaunchAgents/com.example.matrix-bot.plist
#   （plist 内の hermes CLI のパス・WorkingDirectory・HERMES_HOME を実パスに）
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.matrix-bot.plist
```

ログイン認証情報は `$HERMES_HOME/.env` から読まれます（plist に秘密は
書かない）。動作確認は Element X から bot に DM を送るだけ。返事が
15 秒前後で来ます（頭脳の速度次第）。

---

## 7. 運用

### 見張り（watchdog）

`scripts/matrix-watchdog.sh` を 5 分ごとに回すと、切れた段だけ自動修復します:

```
tailscaled → colima/Docker → コンテナ → 127.0.0.1:8008 → tailscale serve → bot プロセス
```

- 同一段の修復は 10 分に 1 回まで。3 連敗したら修復をやめて警報だけ出す
  （`ALERT_HOOK` に通知スクリプトを渡す）。
- 停止: `touch .watchdog-stop` / ドライラン: `WD_DRY=1 ./matrix-watchdog.sh`

### バックアップ

`scripts/standby-backup.sh` — 毎日 1 回、別マシンへ DB を同期します。

- **ホット方式（macOS）**: APFS のローカルスナップショットから rsync ＝
  サーバーを止めない。RocksDB はスナップショット時点の整合コピーが取れる。
- **コールド方式（フォールバック）**: `docker stop → rsync → docker start`
  （30 秒の停止・trap で復旧保証）。Linux ではコールド方式か
  rocksdb checkpoint を使う。

### よくある故障

| 症状 | 見る場所 |
|---|---|
| スマホからだけ繋がらない | tailnet ACL の `tcp:443` 許可 |
| bot が黙る（プロセスは生きている） | gateway.log の `stopping sync` / `No adapter` マーカー → 再起動 |
| 通知だけ届かない | コンテナの外向き DNS（`colima --dns`）と push gateway への接続 |
| `/_matrix` が 502 | serve status でパスが消えてないか → `serve-paths.sh` で再設定 |

---

## 8. 通知とプライバシー（実測）

- **iOS の Element X 通知**は、Element 社が運営する push gateway（Sygnal、
  `matrix.org` 上）→ Apple APNs 経由で届きます。自前 Sygnal は自前ビルドの
  アプリと APNs 鍵が必要で、**App Store 版 Element X では使えません**。
  つまり iOS の通知を求めるなら、通知のメタデータは Apple/Element の経路を
  通ることを受け入れることになります（本文が暗号化されていても
  「部屋に何か届いた」という事実は通る）。
- **平文部屋のペイロードには本文が乗ります。** E2EE 部屋なら push ペイロードは
  room_id と event_id だけ（本文は復号まで出ない）ですが、平文部屋では部屋名・
  送信者・本文がそのまま APNs に流れます。**機密性の高い部屋は E2EE 化するか、
  通知をオフにする**のが安全です。このレシピの bot 構成は平文前提なので、
  通知に流れる内容には注意してください。
- Android の Element X は UnifiedPush（ntfy など自前サーバー）が選べるため、
  Android 主体なら通知まで完全自前化できます（iOS は上記の制約あり）。
- **通知が届くかの実測方法**: Element X → 設定 → 通知 →
  「Troubleshooting」の **Test Push Gateway** / **Test Push Loop Back** を実行し、
  **Push History** を見る。届かないときはこの順で潰す:
  ① コンテナの外向き DNS/HTTPS（`colima --dns 1.1.1.1`）② 通知設定の
  「Enable notifications on this device」を一度オフ→オン（ログアウト→再
  ログインで pusher が再登録されない既知バグの回避）③ 端末の MagicDNS
  ④ プライベートリレー／VPN。
- **通知は 2 段階**で届く（push gateway が鳴らす → Element X が homeserver から
  本文を取得）。後段は Tailscale の道なので、Tailscale が死んでいると
  通知音だけして本文が取れない・遅延する。

---

## 9. 落とし穴（実測ベースの gotchas）

1. **server_name は永久**。変えると全 ID・部屋・履歴が無効。
2. **E2EE は bot を殺す。** macOS では bot 側の暗号化ライブラリ（libolm）が
   ビルドできない。部屋に `m.room.encryption` を立てると bot は全部読めなく
   なる。平文運用で通す。
3. **同じ server_name のサーバーを 2 台で同時起動しない**（split brain ＝
   同じアカウントが 2 つの DB に書かれ、履歴が永遠に不一致になる）。
   待機系を作る場合は必ず片方を止めてからもう片方を上げる。
4. **Conduit v0.10.15 は `well_known_client` を無視する。** discovery は
   「入力ホスト名の `/.well-known`」（手順 2）が正本。Conduit 自身の
   `8008/.well-known` は古い名前を返しても誰も見ない。
5. **ログイン応答に `well_known` は無い。** クライアントは入力 URL を
   使い続けるため、URL の打ち間違いはログイン失敗で即気づける。
6. **tailnet ACL**。新しく serve したポートは、スマホ側の許可（`tcp:443`）を
   ポリシーに足すまでタイムアウトする。サーバー自身からの curl は誤検出が
   あるので、確認は別端末から。
7. **tailscale serve のエントリは競合で消えることがある。** 書き換えのたびに
   `serve status` で確認し、消えたら足し直す（watchdog がこれをやる）。
8. **コンテナの DNS**。colima 既定だと外向き名前解決が死ぬことがあり、
   通知（push gateway への接続）だけが黙って落ちる。`--dns 1.1.1.1` を推奨。
9. **Element X ではアカウントを作れない**。API＋登録トークンで作る（手順 4）。
10. **M_UNRECOGNIZED が出る場合**、使っているクライアント API のバージョン
    （`v3`）とサーバーの実装差。Conduit v0.10.15 は v3 エンドポイント対応。
11. **QR コードログイン・通話は使えない。** QR ログイン（MSC4108）は MAS 必須、
    通話（Element Call）は LiveKit SFU の別構築が要る。coturn（TURN）を足しても
    Element X の通話は直らない。
12. **お気に入り（タグ）と全文検索は Conduit では黙って捨てられる／非対応。**
    新規部屋の招待が一覧に出てこない報告（sliding sync 系）や、EX の同期が
    数分遅れて追いつく報告もある。実用上は「いったん部屋を開けば出る」。
13. **メディアの purge ができない**（S3 も非対応）＝DB とメディアは単調増加。
    ディスク監視を入れること。`max_request_size`（既定 20MB）を上げたら
    クライアントの再起動で反映される。
14. **登録トークンは静的な 1 本**（config に書くだけ）。期限付きの複数トークンが
    要ればフォーク（Continuwuity の admin room トークン等）を検討する。
15. **「読んでも既読にならない」は本家 Conduit の既知の未修正バグ。**
    Element X の既読・入力中表示は sliding sync の受領拡張（MSC3960）で
    届くが、Conduit v0.10.15 はこの応答を常に空で返す（ソース確認:
    `sync.rs` で `receipts.rooms` / `typing.rooms` がハードコードで空）。
    既読リクエスト自体はサーバーに正しく保存されるので、データは失われて
    いない。応急処置は部屋一覧の長押し →「既読にする」。恒久直しは
    フォークへの移行（conduwuit 0.4.6+ / continuwuity は受領拡張実装済み。
    tuwunel も一部の未読マーカー問題を自認して修正中）。Synapse は
    element-hq/synapse#17617 で同種のバグ（自分の既読が sliding sync に
    返らない）を修正済み。

---

## 10. 待機系（オプション）

DB を毎日別マシンへ同期しておけば、サーバー機が死んでも数分でチャットを
復活できます（手順と戻し手順: `docs/failover.md`）。同期先を「待機系」として
常時電源オフにしておき、障害時に DB を入れ替えて起動するだけです。

## 11. 長期の視点: Conduit の開発停滞とフォーク

Conduit の開発は実質 1 人でペースが落ちています（メディア purge なし・S3 なし・
機能追加はゆっくり）。コミュニティではフォークへの移行が進んでいて:

- **Tuwunel** — Conduit からの移行を公式支持（DB 無傷で移行できた実例あり）
- **Continuwuity** — conduwuit 系コミュニティフォーク（admin room での
  期限付き登録トークン発行など Conduit にない機能あり）

「今の構成で困っていないなら Conduit のまま」でよいですが、移行を検討する時は
**移行先でも server_name と DB のバックアップはそのまま**使えます（移行実績は
「全アカウント・内容無傷」）。このレシピの tailscale serve・well-known・bot 側は
変えずに済むはずです。

---

## Credits

- [Conduit](https://conduit.rs) — Matrix homeserver (Apache-2.0)。
  設定仕様は[公式 docs](https://docs.conduit.rs/)と[v0.10.15 ソース](https://gitlab.com/famedly/conduit)で確認
- [Element X](https://element.io) — クライアントアプリ。
  [要件（element-meta#1915）](https://github.com/element-hq/element-meta/issues/1915)と
  [sliding sync 移行アナウンス](https://matrix.org/blog/2024/11/14/moving-to-native-sliding-sync/)を参照
- [Tailscale](https://tailscale.com) — ネットワーク（serve / ACL）
- [Hermes Agent](https://hermes-agent.nousresearch.com) — bot gateway（Nous Research）
- 参考にしたコミュニティ知見: r/selfhosted・Hacker News のセルフホスト事例、
  [Tailscale×iCloud Private Relay の既知問題](https://github.com/tailscale/tailscale/issues/21677)、
  [Element X iOS の pusher 再登録バグ](https://github.com/element-hq/element-x-ios/issues/2602)

## License

MIT — 詳細は [LICENSE](LICENSE)
