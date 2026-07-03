# TORANOI 開発指針 v2（2026年7月版）

対象環境：Ryzen 7 7700 / RX 9060 XT 16GB / DDR5 32GB / Arch Linux（rEFInd）
リモート：ノートPC（Core Ultra 7 258V）・iPhone 16e → Tailscale経由でデスクトップに接続

---

## 0. v1からの大転換ポイント（結論だけ先に）

| 論点 | v1（旧） | v2（今回） |
|---|---|---|
| Lemonade | 初心者向けの踏み台 → 後でOllamaへ「移行」 | **移行という概念を廃止**。トラノイはOpenAI互換APIだけに依存する設計にして、ランタイム（Ollama / Lemonade / vLLM）を差し替え可能に |
| 最初のランタイム | Lemonade → Ollama | **最初からOllama**。Lemonadeは「詰まった時の脱出口」と「マルチモーダル拡張」に温存 |
| モデル | Qwen3-30B-A3B / Qwen3:14B / DeepSeek-R1:14B / Gemma4:27B | **Qwen3.5:9b（本命）+ GPT-OSS-20B + Qwen3-Coder-30B** に世代交代 |
| 挫折対策 | フェーズ分けのみ | 各フェーズに **完了条件（DoD）・時間上限・脱出ルート** を明記 |

---

## 1. Lemonadeを体験する必要性 → 「必要」から「保険と拡張」へ

2025年時点では「AMD GPUでのセットアップ地獄を回避するオンランプ」としてLemonadeに意味があった。2026年7月現在、前提が変わった。

- **Ollama側が追いついた**：Ollama 0.30系 + ROCm 7.1系で、RX 9060 XT（RDNA4 / gfx1200）はDLL差し替えや偽装なしにネイティブ動作するようになった
- **Lemonade側も進化した**：v10.8（2026年6月）でMCPサーバー統合、ROCm 7同梱（別途セットアップ不要）、vLLM ROCmバックエンド（実験的、RDNA4向けビルドあり）、Arch向けインストールパスも公式にある
- **両者ともOpenAI互換API**を喋る（LemonadeはAnthropic互換も）

つまり「どっちを選ぶか」で悩む必要がなくなった。**トラノイのバックエンドコードがOpenAI互換エンドポイント（`/v1/chat/completions`）だけを叩く設計なら、ランタイムは環境変数1個で差し替えられる。**

Lemonadeの現在の立ち位置：

1. **脱出ルート**：ArchでROCm周りが壊れた時、ROCm同梱のLemonadeはシステムのROCmと切り離されているので復旧が速い
2. **マルチモーダル拡張**：STT（Whisper）/ TTS（Kokoro）/ 画像生成（SD）を1サーバーで提供。トラノイに音声機能を足す日が来たらここ
3. **注意**：Ryzen 7 7700にNPUはない（既知）。LemonadeのNPU/Hybrid機能は完全に無関係。使うとしても `llamacpp:rocm` バックエンドのみ

---

## 2. Arch Linux × ROCm の親和性 → 高いが「ローリングリリース事故」に備える

**良い点**

- `ollama`（ROCm対応ビルド）も `rocm-hip-sdk` も公式リポジトリにある数少ないディストリ。AURに頼らず最新が入る
- RDNA4対応はROCm 7.1系で本格化しており、常に新しいArchはむしろ有利

**悪い点と対策**

- ローリングリリースゆえ、Ollama / ROCm / カーネルのバージョンずれで突然CPUフォールバックする事故が起きうる（2026年3月、Arch + RX 9060 XTでまさにこの報告あり）
- 対策3点セット：
  1. **Ollamaは0.30.6以降を維持**（gfx1200ネイティブ対応ライン）
  2. **起動ログ確認を癖にする**：`journalctl -u ollama | grep "inference compute"` で `library=ROCm compute=gfx1200` が出ていればGPU駆動
  3. **Vulkanフォールバック**：ROCmが壊れたら `OLLAMA_VULKAN=1` で凌ぐ（RADVは枯れていて安定）。それもダメならLemonadeへ
- `pacman -Syu` 前にbtrfsスナップショット or Timeshiftを仕込んでおくと精神が安定する

---

## 3. モデル選定（2026年7月時点）

旧候補は全部世代交代した。16GB VRAM + DDR5 32GBでの現行推奨：

| 用途 | モデル | サイズ感 | メモ |
|---|---|---|---|
| 汎用・日本語・講義資料解説 | **Qwen3.5:9b** | Q4で約9GB / Q8で約13GB | 日本語性能がこのクラスで頭一つ抜けてる。**VLM対応なので図入り講義資料の画像理解もいける**。トラノイのデフォルトモデル候補 |
| コーディング補助 | **GPT-OSS-20B** | MXFP4で16GBにフィット | MoEで爆速（RTX 4080実測で100t/s超級）。推論・整理も強い |
| コーディング（重め） | **Qwen3-Coder-30B** | Q4で約20GB → 一部CPUオフロード | MoE（A3B）なのでオフロードしても実用速度。DDR5 32GBが活きる |
| 高速MoE枠 | GLM-4.7-Flash | 〜16GB前後 | コンテキスト長を稼ぎたい時の選択肢 |

**量子化まわりで押さえること**

- Q4_K_M が品質/サイズの基準点。Q8は品質微増・速度3割減くらいの感覚
- **MoE + CPUオフロード（llama.cppの `--n-cpu-moe`）**：Expert重みをRAMに逃してAttentionだけVRAMに残す技。16GB超級のMoEモデルが実用域に入る。2026年の最重要テク
- `num_ctx`（コンテキスト長）はVRAMを食う。「モデルが載る」≠「使いたい文脈長で載る」。`ollama ps` でGPU/CPU比率を必ず確認

---

## 4. 新ロードマップ（挫折防止版）

設計原則：**「最初のトークン生成」を初日に持ってくる。**  各フェーズにDoD（完了条件）・時間上限・脱出ルートを付ける。時間上限を超えたら悩まず脱出ルートへ。

```
PHASE 0「最初のトークン」      1日
PHASE 1「リモート環境を固める」 3日〜1週間
PHASE 2「APIとモデルを使い倒す」2〜3週間
PHASE 3「トラノイを作る」      1〜3ヶ月
PHASE 4「深める」              以降ずっと
```

### 🟡 PHASE 0「最初のトークン」（1日）

```bash
sudo pacman -S ollama        # ROCm対応ビルド
sudo systemctl enable --now ollama
ollama pull qwen3.5:9b
ollama run qwen3.5:9b "自己紹介して"
journalctl -u ollama | grep "inference compute"   # ROCm認識チェック
```

- **DoD**：GPU駆動（`library=ROCm`）で1回返答が返る
- **脱出ルート**：ROCm認識せず → `OLLAMA_VULKAN=1` → それでもダメ → Lemonade（ROCm同梱、Arch対応）
- 旧PHASE 0の「ROCm SDK手動導入」は不要になった。Ollamaのパッケージが必要なものを持ってくる。詰まった時だけ`rocm-smi`等を入れて調査

### 🟢 PHASE 1「リモート環境を固める」（3日〜1週間）

- `ollama.service` に `Environment="OLLAMA_HOST=0.0.0.0"` を追加（デフォルトはlocalhost限定）
- Tailscale経由でノートPCから `curl http://<tailscale-ip>:11434/api/tags`
- 既存の宿題を回収：**WoL → rEFInd自動起動 → 自動ログイン → ollama自動起動** の全自動フロー完成（自動ログインはディスプレイマネージャの特定が残タスク）
- Open WebUIをDockerで立てる → 旧PHASE 1でLemonade GUIに期待してた「気軽に触る体験」はここで代替
- **DoD**：ノートPCとiPhoneのブラウザからチャットできる

### 🔵 PHASE 2「APIとモデルを使い倒す」（2〜3週間）

ここが転換点なのは変わらず。ただし**Ollama独自APIじゃなくOpenAI互換エンドポイントで書く**のがv2の肝：

```python
from openai import OpenAI
client = OpenAI(base_url="http://<tailscale-ip>:11434/v1", api_key="dummy")
res = client.chat.completions.create(
    model="qwen3.5:9b",
    messages=[{"role": "user", "content": "電通大の講義を説明して"}],
    stream=True,
)
```

- こう書いておけばPHASE 3のトラノイがLemonadeにもvLLMにも無改造で繋がる
- やること：ストリーミング / system prompt / `num_ctx`調整 / Qwen3.5・GPT-OSS-20B・Qwen3-Coder-30Bの3種比較 / Q4 vs Q8 / `--n-cpu-moe`実験
- **DoD**：「コーディングはこれ、日本語壁打ちはこれ」と用途別のマイ定番が言える

### 🟣 PHASE 3「トラノイを作る」（1〜3ヶ月）

スタックは既定路線のまま：React + Vite + Tailwind / Axum（Rust）+ SQLite（sqlx）。
一気に作らずマイルストーンを刻む（挫折防止の要）：

| M | 内容 | 完了条件 |
|---|---|---|
| M1 | 最小チャット | Axum経由でストリーミング応答が画面に流れる |
| M2 | 履歴 + モデルセレクタ | SQLiteに会話保存、`/api/tags`からモデル自動取得 |
| M3 | トークンカウンタ + Thinking可視化 | 使用量バー表示、思考部分の折りたたみUI |
| M4 | PDFドロップ解析（RAG） | 講義PDFを投げてQ&Aできる |
| M5 | 会話要約でコンテキスト継続 | 長い会話が要約経由で続く |

- RAGの埋め込みモデルもOllamaで動く（`bge-m3`等の多言語埋め込みが日本語講義資料向き）
- Qwen3.5がVLMなので、M4では「PDFをテキスト抽出」だけでなく「ページ画像をそのまま投げる」ルートも試せる

### 🔴 PHASE 4「深める」（以降ずっと）

- **vLLM on ROCm**：Lemonadeの実験バックエンド経由が最短。継続バッチングや並行処理を学ぶ
- **量子化を自分でやる**：HuggingFaceのモデルをGGUF変換 → imatrix量子化まで
- **LoRAファインチューニング**：正直に言うと**RDNA4 16GBでのローカル学習はまだ茨の道**（学習系ツールのROCm対応はNVIDIAに数年遅れ）。小型モデル（4B級）+QLoRAで挑むか、学習だけクラウドGPUを借りて推論はローカル、が現実解
- 論文実装・Transformerアーキテクチャ読解は変わらず

---

## 5. 運用メモ

- **月1回**：`ollama --version` とモデルの世代交代をチェック（このジャンルは3ヶ月で常識が変わる。この文書も2026年7月時点のスナップショットにすぎない）
- **バージョン固定**：トラノイ開発中はOllamaのメジャー更新を急がない。動く組み合わせをメモっておく
- **ログ確認コマンド集**：`ollama ps`（GPU/CPU比率）、`journalctl -u ollama -f`、`rocm-smi`（VRAM使用量）
