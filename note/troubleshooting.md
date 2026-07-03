# Troubleshooting Notes

TORANOI プロジェクトを進める中で遭遇したハマりどころと、その解決策の記録。
自分自身の備忘録であり、同じ環境（Arch Linux + RX 9060 XT + Ollama）を再構築する時の生存戦略でもある。

## PHASE 0：最初のトークンまで

### 1. `ollama` パッケージだけ入れるとCPUで動く

**症状**

```bash
journalctl -u ollama | grep "inference compute"
# → library=cpu compute="" name=cpu ...
```

`sudo pacman -S ollama` を実行し、サービスが `active (running)` になっても、GPU（ROCm）ではなくCPUで動いてしまう。

**原因**

Arch の `ollama` パッケージには、ROCm バックエンドが同梱されていない。ROCm を使うには **別パッケージ `ollama-rocm` を追加インストール** する必要がある。

**解決策**

```bash
sudo pacman -S ollama-rocm
sudo systemctl restart ollama
journalctl -u ollama | grep "inference compute"
# → library=ROCm compute=gfx1200 name=ROCm0 description="AMD Radeon RX 9060 XT"
```

新しい行に `library=ROCm compute=gfx1200` が出ていれば成功。

---

### 2. pacman インストール中の 404 エラーはノイズ

**症状**

```
エラー: ファイル 'ollama-...' を fastly.mirror.pkgbuild.com から取得するのに失敗しました : 404
エラー: ファイル 'ollama-...' を geo.mirror.pkgbuild.com から取得するのに失敗しました : 404
（複数のミラーで404）
```

**原因**

pacman が複数ミラーに並列で問い合わせている際、一部ミラーの同期ズレで 404 が返ることがある。**どこか1つで取得成功していれば実害はない**。

**判定基準**

- ダウンロード進捗バーが `100%` に到達している
- 後続の `(1/1) キーリングのキーを確認` 以降のフックが完走している
- 最後に `Arming ConditionNeedsUpdate` などのフック終了ログが出ている

これらが揃っていればインストール成功。404 メッセージは無視してよい。

---

### 3. `rocm-smi: command not found`

**症状**

```bash
watch -n 0.5 rocm-smi
# → sh: 行 1: rocm-smi: command not found
```

**原因**

`ollama-rocm` に含まれるのは Ollama が動くのに必要な ROCm ランタイムのみで、監視ツール `rocm-smi` は別パッケージ。

**解決策**

```bash
sudo pacman -S rocm-smi-lib
```

PATH が通っていない場合の対策：

```bash
# 実体を直接呼ぶ
/opt/rocm/bin/rocm-smi

# .bashrc にパスを追加
echo 'export PATH=$PATH:/opt/rocm/bin' >> ~/.bashrc
source ~/.bashrc
```

---

## モデルの挙動系

### 4. Thinking モードで回答本文が出ずに終了する

**症状**

`Thinking...` の後に長い思考プロセスが表示され、`...done thinking` の後、**回答本文がゼロ文字で終了する**。

**原因**

Qwen3.5 の Thinking モードは、答える前の推論に大量のトークンを消費する。特に **知識が曖昧なトピックや、スコープが広いお題** では、思考ループが延々続き、`num_predict`（出力トークン上限）を Thinking だけで使い切ってしまう。

**解決策の選択肢**

| 手段                  | やり方                                | 向いてる場面                      |
| --------------------- | ------------------------------------- | --------------------------------- |
| A. Thinking を切る    | `/set nothink`（REPL 内）             | 速度優先、既知の話題              |
| B. 出力枠を増やす     | `/set parameter num_predict 8192` 等  | 精度必要、Thinking の恩恵が欲しい |
| C. プロンプトを構造化 | 「以下の順で説明して：1. ... 2. ...」 | 広いテーマを絞る                  |

C は特に効果的で、モデルが「構成を考える」フェーズを省略できるため、Thinking の暴走を防げる。

---

### 5. `/no_think` を文中に書いても効かない

**症状**

```bash
ollama run qwen3.5:9b "/no_think 質問文"
```

これを実行しても、モデルは Thinking を実行してしまう。

**原因**

`/no_think` は **モデルへの「お願い」として解釈される** ため、モデルが「システム指示的に考えた方が良さそう」と判断すると **無視される**。プロンプトの一部として送られるだけで、Ollama 側の制御コマンドではない。

**解決策**

REPL 内で **セッション変数として設定** する：

```
ollama run qwen3.5:9b
>>> /set nothink
Set 'nothink' mode.
>>> 質問文
```

`Set 'nothink' mode.` が返ってきていれば、以降の入力で Thinking が無効化される。

---

### 6. `nothink` モードだと固有名詞のハルシネーションが激増する

**症状**

`nothink` モードで固有名詞（大学名、組織名、人物名）を含む質問をすると、**もっともらしい嘘の情報**が返る。

例：「電気通信大学について教えて」→ 「株式会社 電気通信大学」「私立大学」「杉並区にキャンパス」など全滅（正しくは国立大学法人、調布市）。

**原因**

Thinking モードには「あれ、この情報怪しいな」と自己検証する余地があるが、`nothink` は **最初に思いついた情報を検証なしで出力する**。9B 級モデルはマイナー固有名詞への知識が薄いため、この差が顕著に出る。

**対策**

| タスクの性質                         | 推奨モード                                   |
| ------------------------------------ | -------------------------------------------- |
| 講義解説・レポート補助（正確性重視） | `think` のまま                               |
| コード相談・雑談（速度重視）         | `nothink` OK                                 |
| 固有名詞・年号・数値を含む質問       | **必ず `think`、かつ結果はファクトチェック** |

ローカル 9B モデルの回答を無検証で使うのは危険。特に固有名詞・数値は独立ソースでの検証を必ず行う。

---

### 7. 応答が同じ場所付近で毎回途中で切れる

**症状**

`num_predict` を大きくしても、長文生成が **同じあたり（1000〜1500トークン程度）で必ず切れる**。

**原因**

`num_predict`（出力トークン上限）とは別に、`num_ctx`（コンテキスト長 = プロンプト + 会話履歴 + 生成中の応答の合計上限）が存在する。Ollama のデフォルトは **`num_ctx=4096`** で、会話を重ねると累積で枠切れを起こす。

**解決策**

```
>>> /clear
>>> /set parameter num_ctx 8192
>>> /set parameter num_predict 4096
>>> 質問文
```

- `/clear`：会話履歴をリセットして枠を空ける
- `num_ctx 8192`：コンテキスト枠を倍増（16GB VRAM なら余裕）
- `num_predict 4096`：出力上限。過大にすると VRAM を圧迫するので現実的な値に

**注意**

`num_ctx` を上げると VRAM 消費が増える。`ollama ps` で GPU/CPU 比率を必ず確認し、GPU に載りきらずに CPU オフロードが発生していないかチェックする。

---

### 8. コマンドをコピペしたら `>>>` が二重になって効かない

**症状**

```
>>> >>> /set parameter num_predict 16384
I cannot change my system parameters or model settings ...
```

コマンドが効かず、モデルが「そんな指示できません」と返答してしまう。

**原因**

REPL のプロンプト記号 `>>> ` をコピーごと貼り付けると、行の先頭が `>>> /` となり、**`/` から始まらないのでコマンドとして認識されず、ただのテキストとしてモデルに渡る**。

**解決策**

コマンドは `/` から始まるように、プロンプト記号を除いてコピペする：

```
/set parameter num_predict 16384
```

正しく認識されると `Set parameter 'num_predict' to '16384'` が返る。

---

## Ollama 運用系

### 9. デフォルトでは外部から接続できない

**症状**

Tailscale 経由で別 PC やスマホから `curl http://<tailscale-ip>:11434/api/tags` しても繋がらない。

**原因**

デフォルトの `ollama.service` は **`127.0.0.1`（localhost）のみでリッスン**している。

**解決策**

systemd の drop-in で環境変数を追加する：

```bash
sudo systemctl edit ollama
```

エディタで以下を追記：

```ini
[Service]
Environment="OLLAMA_HOST=0.0.0.0"
```

保存後：

```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama
```

これで Tailscale 経由の LAN からアクセス可能になる。

---

## ハマりどころチェックリスト

新規環境構築時、以下を順にチェックすると多くのハマりを回避できる：

- [ ] `ollama-rocm` を入れたか（`ollama` だけでは CPU 動作）
- [ ] `journalctl -u ollama | grep "inference compute"` で `library=ROCm` を確認したか
- [ ] `rocm-smi-lib` を入れたか（監視用）
- [ ] `OLLAMA_HOST=0.0.0.0` を設定したか（リモート用）
- [ ] `num_ctx` のデフォルト（4096）を意識しているか
- [ ] 固有名詞を含む質問は `think` モードで、かつ結果をファクトチェックする運用ができているか

---

## 参考ログ収集コマンド

問題発生時にまず実行すべきコマンド：

```bash
# Ollama の稼働状況
systemctl status ollama

# 推論バックエンドの確認
journalctl -u ollama | grep "inference compute"

# 全体ログ（直近）
journalctl -u ollama -n 100 --no-pager

# 現在ロード中のモデルと GPU/CPU 比率
ollama ps

# GPU の状態
rocm-smi
```
