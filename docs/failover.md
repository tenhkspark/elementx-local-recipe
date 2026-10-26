# Failover — サーバー機が死んだら待機系で数分で復活させる

対象: 障害時にスマホのチャットを復活させたい人。
待機系には毎晩のバックアップ（`scripts/standby-backup.sh` の同期先）と
Docker イメージ・設定ファイルを置いておく。

**失うメッセージは最後のバックアップ以降の分だけ。** それ以前の全履歴は残る。

## 絶対ルール: 本番と待機系を同時に動かさない

同じ `server_name` の homeserver が 2 台あると split brain になる（同じ
アカウントが 2 つの別 DB に書き込まれ、履歴が二度と一致しない）。
本番機が復活したら必ず「戻す手順」までやること。本番機が死んでいて
止められないなら、そのまま進めてよい（片方しか生きていないので
split brain にはならない）。

## 復活手順（待機系マシンで）

1. 待機 DB を本番位置へ入れ替える:
```bash
cd ~/matrix-stack
mv db db.pre-failover-$(date +%Y%m%d)   # 壊れないよう退避（消さない）
mv db.standby db
```
2. サービスを上げる（Linux の場合・macOS なら launchd で同様に）:
```bash
docker start matrix-server
docker update --restart unless-stopped matrix-server
```
3. tailscale serve を張る:
```bash
sudo tailscale serve --bg --set-path /_matrix http://127.0.0.1:8008/_matrix
sudo tailscale serve --bg --set-path /.well-known http://127.0.0.1:9111/.well-known
```
4. 確認: `curl -s http://127.0.0.1:8008/_matrix/client/versions` が JSON を返す。
5. スマホの Element X: 接続先を待機系のホスト名（例:
   `https://standby.example.ts.net`）に変えてログインし直す。
   部屋と履歴はそのまま出る。

## 本番機が復活したら戻す手順（ここまで含めて完了）

1. 待機系を寝かせる:
```bash
docker stop matrix-server && docker update --restart=no matrix-server
sudo tailscale serve --https=443 off
```
2. 待機系で使っていた間の差分を本番機に戻す（**忘れると障害中の会話が消える**）:
```bash
# 待機系で: docker が完全停止（cold）を確認してから
tar czf ~/matrix-back-$(date +%Y%m%d).tgz -C ~/matrix-stack db
# 本番機（生きている shell）へ:
scp standby.example.ts.net:~/matrix-back-*.tgz .
# 本番機のサーバーを止めて差し替え
docker stop matrix-server
mv db db.pre-return-$(date +%Y%m%d)
tar xzf matrix-back-*.tgz -C ~/matrix-stack/
docker start matrix-server
```
3. 本番機が全部生きていることを確認（`curl -s
   http://127.0.0.1:8008/_matrix/client/versions`、bot のログに同期成功マーカー）。
4. スマホの Element X を本番機のホスト名に戻す。
5. 待機系の `db.standby` は次回のバックアップで自動更新される。

## ヒント

- 待機系の tailscale serve は普段張らない（本番機と同じホスト名ではなく、
  待機系自身の名前で張る）。ACL でスマホ → 待機系の `tcp:443` を事前に
  許可しておくと障害時に詰まらない。
- バックアップは「スナップショット方式（無停止）」が第一選択。
  スナップショットが取れない環境ではコールド方式にフォールバックする
  （`standby-backup.sh` は両方を実装済み）。
