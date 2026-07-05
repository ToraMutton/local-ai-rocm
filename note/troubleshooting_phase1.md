# Troubleshooting Notes — PHASE 1

TORANOI プロジェクト PHASE 1「リモート環境を固める」で遭遇したハマりどころの記録。
対象環境：Arch Linux + RX 9060 XT + Ollama / Tailscale / Docker(Open WebUI, netdata) / Windows 11 + WSL2(Arch)

---

## Tailscale・ネットワーク系

### 1. Tailscale の認証 URL は使い捨ての合鍵

**症状（というより注意点）**

```
To authenticate, visit:
    https://login.tailscale.com/a/xxxxxxxxxxxx
```

**性質**

- この URL は「このマシンを自分のアカウントに紐付けるためのワンタイムリンク」
- 他人が踏むと **自分の Tailnet に他人のデバイスが参加してしまう** 可能性がある
- 一定時間で失効するが、スクショ・ログに残す時は伏せるのが安全

**運用ルール**

- 認証 URL・Webhook URL の類は「一時的な鍵」として扱い、公開の場に貼らない

---

### 2. Tailscale IP（100.x.x.x）はグローバル IP ではない

**Tailscale が割り当てる `100.64.0.0/10` は CGNAT 用の予約レンジ。**

- インターネット全体からは到達できない、Tailnet 内でのみ有効な「内線番号」
- 自宅ルーター（192.168.x.x）と衝突しないためにこのレンジが使われている
- ポート開放・ルーター設定（NURO 等）は不要。双方が外向きに接続して繋がる方式

---

### 3. WSL2 には Tailscale を入れない（Windows 側に入れる）

**構成**

- ノート PC：Windows 11 + WSL2(Arch)
- Tailscale は **Windows ホスト側にインストール** する

**理由**

WSL2 の通信は Windows のルーティングテーブルを間借りして外に出る。Windows 側に Tailscale があれば、WSL2 内からも `100.x.x.x` 宛の通信は自動的に Tailscale 経由で届く。WSL2 内に入れると二重ネットワークになり不安定。

**確認方法（WSL2 内から）**

```bash
curl http://<デスクトップのtailscale-ip>:11434/api/tags
```

---

### 4. Windows 版 `tailscale` コマンドが PowerShell で見つからない

**症状**

```powershell
tailscale ip -4
# → コマンドが見つからない
```

**原因**

GUI アプリとしてインストールされるため、PATH に登録されないことがある。

**解決策**

```powershell
& "C:\Program Files\Tailscale\tailscale.exe" ip -4
```

---

### 5. 再起動後にノート PC が Tailnet からオフラインになっている

**症状**

管理画面（login.tailscale.com/admin/machines）で該当マシンの LAST SEEN が古く、Connected にならない。デスクトップの Open WebUI にもアクセスできない。

**原因**

Windows 側の Tailscale アプリが起動していない（手動 Quit、更新後の停止など）。

**解決策**

- タスクトレイに Tailscale アイコンがあるか確認
- 無ければスタートメニューから Tailscale を起動 → 自動でログイン状態が復元される
- 管理画面をリロードして Connected になれば OK

---

## WSL2 系

### 6. `wsl.conf` の重複キー警告

**症状**

```
wsl: Duplicated config key 'automount.options' in /etc/wsl.conf:19
(Conflicting key: 'automount.options' in /etc/wsl.conf:6)
```

**原因**

`[automount]` セクションがファイル内に 2 回定義されていた（過去の追記時に既存セクションを見落とし）。INI 形式では同一セクションの重複は NG。

**解決策**

```bash
# バックアップしてから重複ブロックを除去
sudo cp /etc/wsl.conf /etc/wsl.conf.bak
sudo sed -n '1,17p' /etc/wsl.conf > /tmp/wsl.conf.new
sudo cp /tmp/wsl.conf.new /etc/wsl.conf
```

反映には WSL の再起動が必要（下記 7 参照）。

---

### 7. `wsl --shutdown` は WSL の中では実行できない

**症状**

```bash
$ wsl --shutdown
-bash: wsl: command not found
```

**原因**

`wsl.exe` は Windows 側のコマンド。WSL（Linux）内には存在しない。

**解決策**

Windows 側の PowerShell から実行する：

```powershell
wsl --shutdown
# 数秒待ってから
wsl -d Arch
```

`wsl.conf` は起動時にのみ読まれるため、設定変更後はこの手順が必須。

---

## Docker 系

### 8. `usermod -aG docker` してもグループが反映されない

**症状**

```bash
sudo usermod -aG docker $USER
groups
# → toramutton wheel   （docker が出ない）
```

ターミナル（kitty）を閉じて開き直しても変わらない。

**原因**

グループ情報は **デスクトップセッションへのログイン時に一度だけ読み込まれる**。ターミナルの開き直しは「セッション内の新しい窓」でしかなく、再読込は起きない。

**解決策**

| 方法 | 効果範囲 |
| --- | --- |
| `newgrp docker` | そのターミナルのみ即時反映（暫定） |
| デスクトップセッションからログアウト → 再ログイン | 恒久反映（推奨） |

再ログイン後は `groups` に `docker` が出て、`sudo` なしで docker コマンドが使える。

---

### 9. `--network=host` のコンテナは `docker ps` の PORTS 欄が空

**症状**

`docker ps` で Open WebUI の PORTS 欄に何も表示されない。

**原因**

`--network=host` はホストのネットワークをそのまま間借りするため、Docker のポートマッピング表示の仕組みの対象外になる。**異常ではない**。

実際の待ち受けポートはアプリ側の仕様で決まる（Open WebUI は 8080、netdata は 19999）。

---

## Open WebUI・モデル挙動系

### 10. 応答が「"The"」だけで止まって見える（実は裏で生成し続けている）

**症状**

Open WebUI 上で「1秒未満の思考」と表示され、本文が 1 単語で止まったように見える。

**ログで見えた実態**

```
slot update_slots: ... n_ctx_slot = 4096, ... n_tokens = 4095, truncated = 1
forcing full prompt re-processing due to lack of cache data
print_timing: ... n_decoded = 1720, tg = 44 t/s   ← 裏では延々生成中
```

**原因（2つの複合）**

1. 会話履歴が `num_ctx` デフォルト値 4096 の上限に張り付き、**毎回フルで再計算** が走って激重になっていた
2. Qwen3.5 の Thinking がトークンを大量消費し、表示側が追いつかない

**解決策**

- 新規チャットを開始する（履歴リセットが即効薬）
- Open WebUI の Advanced Params で `num_ctx` を 8192 に、Thinking をオフに
- **設定変更後の初回リクエストはモデル再ロードが走るため約 1 分待たされる**（`load_tensors: loading model tensors, this can take a while...` がそのログ）。2 回目以降は速い

---

## netdata 系

### 11. `systemctl status` がページャで止まり、後続コマンドが実行されない

**症状**

複数コマンドをまとめて貼ったのに、`lines 1-47/47 (END)` で止まって次が走らない。

**原因**

`systemctl status` は出力が長いと `less`（ページャ）を開いて入力待ちになる。

**解決策**

`q` を押してページャを抜ける。スクリプトで使う場合は `--no-pager` を付ける。

---

### 12. dGPU と iGPU のセンサーを取り違えそうになる

**症状**

netdata の温度一覧に `amdgpu` の `edge` が 2 つ出てくる。

**原因**

Ryzen 7 7700 は iGPU を内蔵しているため、`amdgpu` ドライバのセンサーが 2 系統存在する。

**特定方法**

```bash
sensors
```

- `amdgpu-pci-0300` → RX 9060 XT 本体（`rocm-smi` の `pci_id=0000:03:00.0` と一致）
- `amdgpu-pci-0d00` → 内蔵 iGPU

PCI バスアドレスで突き合わせるのが最も確実。

---

### 13. netdata のカスタムアラートが登録されない（コンテキスト名の不一致）

**症状**

`/etc/netdata/health.d/*.conf` を書いて `reload-health` しても、`/api/v1/alarms?all` に出てこない。

**原因**

`on:` に指定したコンテキスト名が実際のチャート名と一致していなかった。

- 誤：`on: sensors.temperature`
- 実際のチャート ID は `sensors.temperature_amdgpu-pci-0300_temp1_edge_input` のように **センサー 1 個ごとに個別チャート** になっている

**調べ方**

```bash
# 実際に存在するコンテキスト/チャート名を確認
docker exec -it netdata sh -c "curl -s http://localhost:19999/api/v1/charts | grep -oE '\"sensors[a-z0-9_.-]*\"' | sort -u"
```

**さらにハマった点**

- `template:`＋広いコンテキスト指定にすると、**全センサー（CPU/SSD/メモリ含む）に無差別適用** されてしまった
- dimension 名も `edge` ではなく共通の `input`

**最終形（RX 9060 XT の edge 温度だけを狙い撃ち）**

```
   alarm: amdgpu_dgpu_edge_temp
      on: sensors.temperature_amdgpu-pci-0300_temp1_edge_input
   class: Utilization
    type: System
component: Hardware
  lookup: max -1m unaligned of input
   units: Celsius
   every: 30s
    warn: $this > 80
    crit: $this > 85
   delay: down 5m multiplier 1.5 max 1h
      to: alerts
    info: AMD dGPU (RX 9060 XT) edge temperature
```

`template:` は「パターンに一致する全チャートに配る」、`alarm:` は「特定 1 チャート限定」。狙い撃ちには `alarm:` を使う。

---

### 14. コンテナ越しの `sed` で `$this` が化けて置換されない

**症状**

```bash
docker exec -it netdata sh -c "sed -i 's/warn: \$this > 80/.../' ..."
# → エラーも出ないが、ファイルも変わっていない
```

**原因**

外側のシェル → コンテナ内シェルと **2 回シェルを経由** する過程で `$this` のエスケープが崩れ、`sed` が存在しない文字列を探していた（マッチ 0 件は sed にとって正常終了なのでエラーも出ない）。

**解決策**

部分置換をやめ、**heredoc でファイルごと再生成** する方式に統一する。冪等で事故りにくい。

---

### 15. heredoc をコピペしたら `>` プロンプトで固まる

**症状**

```
$ cat > file << 'EOF' ...（1行に潰れて貼られた）
>
```

**原因**

コピペ時に改行が失われ、heredoc の終端 `EOF` が認識されなかった。シェルは「まだ続きがある」と判断して継続入力待ち（`>`）になる。

**解決策**

- `EOF` と打って Enter で強制的に閉じる（または `Ctrl+C` で中断）
- 作られたファイルは中身を必ず確認（`cat` / `wc -l`）。壊れていたら作り直す
- 何度も崩れる場合はエディタ（zed 等）で直接書く方が確実

---

### 16. netdata の Discord 通知設定はコンテナ再起動が必要

**手順まとめ**

```bash
# ひな形をコピー（/etc/netdata 側が上書き用）
docker exec -it netdata sh -c "cp /usr/lib/netdata/conf.d/health_alarm_notify.conf /etc/netdata/health_alarm_notify.conf"

# 3点を設定（sed の区切りに | を使うと URL の / と衝突しない）
SEND_DISCORD="YES"
DISCORD_WEBHOOK_URL="https://discordapp.com/api/webhooks/..."
DEFAULT_RECIPIENT_DISCORD="alerts"
```

**注意点**

- `health_alarm_notify.conf` の変更は `netdatacli reload-health` では反映されない。**`docker restart netdata` が必要**（reload-health はアラート「ルール」専用）
- アラートルール側にも `to: alerts` の行が必要。これが無いと宛先に紐付かない

---

### 17. cgroup ベースの「コンテナ停止検知」は機能しない

**症状**

`cgroup_<コンテナID>.cpu` に `crit: $this == nan` のアラートを張り、コンテナを `docker stop` しても通知が来ない。

**原因**

コンテナが停止すると **cgroup チャート自体が削除（obsolete 化）され、紐付いていたアラートごと消える**。「異常値の検知」ではなく「観測対象の消滅」なので、この方式とは相性が悪い。

**解決策：自作スクリプト方式に切り替え**

`docker inspect` / `systemctl is-active` を直接叩き、状態変化時のみ Discord Webhook に POST する（次項）。

---

## 自作監視スクリプト系

### 18. 監視スクリプトの設計メモ（check_services.sh）

**監視対象と判定方法**

| 対象 | 判定コマンド | 正常値 |
| --- | --- | --- |
| Ollama（systemd サービス） | `systemctl is-active ollama` | `active` |
| Open WebUI（コンテナ） | `docker inspect -f '{{.State.Status}}' open-webui` | `running` |
| ROCm フォールバック | `journalctl -u ollama --no-pager \| grep "inference compute" \| tail -1` | `library=ROCm` を含む |

**設計ポイント**

- **状態ファイル**（/tmp/toranoi_service_state）に前回状態を記録し、「正常 → 異常」の変化時のみ通知（スパム防止）
- ROCm チェックは `--since "5 min ago"` にしない。`inference compute` 行は **モデルロード時にしか出ない** ため、時間で絞ると「ログが無い」だけで誤判定する。全ログから `tail -1` で最新 1 行を取る
- systemd timer（`OnUnitActiveSec=1min`）で 1 分間隔実行。`Type=oneshot`
- タイマー登録直後は `list-timers` の NEXT が `-` になることがあるが、初回実行後に埋まる（正常）

**Webhook URL の管理**

- スクリプト本体に直書きせず、`.env` に分離して `source` で読み込む
- `.env` は `chmod 600` ＋ `.gitignore` に登録。**リポジトリには絶対に含めない**
- Discord Webhook URL は「知っていれば誰でもそのチャンネルに書き込める鍵」

---

## その他

### 19. `/boot` パーティション使用率 92%（未対応・持ち越し）

netdata の標準アラートが検知。放置するとカーネル更新時に容量不足で失敗する恐れがあるため、PHASE 1 完了後の別タスクとして対応予定。

```bash
# 現状確認
df -h /boot
ls -lh /boot
```

---

## ハマりどころチェックリスト（PHASE 1 版）

- [ ] Tailscale は WSL2 ではなく Windows ホスト側に入れたか
- [ ] 再起動後、クライアント側 Tailscale が起動しているか（管理画面で Connected 確認）
- [ ] `OLLAMA_HOST=0.0.0.0` を drop-in（`systemctl edit`）で設定したか
- [ ] `usermod -aG docker` 後にセッション再ログインしたか
- [ ] Open WebUI が重い時、まず新規チャット＋ `num_ctx` を疑ったか
- [ ] netdata のアラートは実在するチャート ID を `/api/v1/charts` で確認してから書いたか
- [ ] dGPU/iGPU の取り違えを PCI バスアドレス（`sensors` × `rocm-smi`）で確認したか
- [ ] Webhook URL / 認証 URL を `.env` 分離＋ `.gitignore` 登録したか
- [ ] コンテナ停止検知は cgroup ではなく `docker inspect` 直叩きにしたか

---

## 参考ログ収集コマンド（PHASE 1 追加分）

```bash
# Tailscale の状態と自分の IP
tailscale status
tailscale ip -4

# コンテナの稼働状況
docker ps
docker logs netdata --tail 50
docker inspect -f '{{.State.Status}}' open-webui

# netdata に登録済みのアラート一覧
docker exec -it netdata sh -c "curl -s http://localhost:19999/api/v1/alarms?all | head -c 2000"

# 監視タイマーの動作確認
systemctl list-timers toranoi-monitor.timer
journalctl -u toranoi-monitor.service -n 20 --no-pager
```
