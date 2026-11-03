# private-actions-cost-reduction

プライベートリポジトリの GitHub Actions の実行コストを下げるための Claude Code プラグインです。

プライベートリポジトリでは、GitHub ホスト型ランナーの実行時間が課金されます（無料枠はドル建て、ジョブごとに 1 分単位で切り上げ）。このプラグインは、ワークフローを書くときの基本ルールと、既存のワークフローを見直すコマンドを提供します。パブリックリポジトリは標準ランナーが無料のため、対象外です。

## インストール

```
/plugin install private-actions-cost-reduction --marketplace tak-solder/claude-code-plugins
```

## 提供するもの

### ワークフローの基本ルール（Tier 0）

`.github/workflows/*.yml` / `*.yaml` を扱うときに自動で読み込まれるスキル（`workflow-tier0-rules`）です。プライベートリポジトリの場合だけ、次のルールに沿ってワークフローを作成・編集・レビューします。

| ルール | 理由 |
|---|---|
| すべてのジョブに `timeout-minutes` を設定する | 既定の 360 分のままだと、ハングしたジョブが最大 6 時間分課金される |
| PR で動くワークフローに `concurrency` を設定する（デプロイ系はキャンセルせず直列化） | 連続して push したとき、結果を見ない古い実行が課金されるのを防ぐ |
| 軽いジョブは `ubuntu-slim` を既定にする | 単価が `ubuntu-latest` の 1/3。短いジョブほど単価の差がそのまま効く |

### `/private-actions-cost-reduction`

既存のワークフローを見直し、実行コストを下げるコマンドです。

1. 直近 30 日の使用量と、費用の大きいワークフローの実行時間（ベースライン）を計測する
2. Tier 3 の施策のうち、どれを試すかと、CI での検証まで行うかをユーザーに確認する
3. Tier 0・Tier 1 の施策は必ず対応する
4. Tier 2 の施策（このリポジトリに当てはまるもの）と、選ばれた Tier 3 の施策を実装し、CI を 3 回以上実行して、効果があったものだけを適用する
5. 対応したもの・対応しなかったもの（理由と計測値つき）を報告する

施策ごとに PR を分けて作成します。PR のマージはユーザーが行います。

| Tier | 施策 | 扱い |
|---|---|---|
| 0 | `timeout-minutes` / `concurrency` / 軽いジョブの `ubuntu-slim` | 必ず対応 |
| 1 | 実行条件の見直し（対象ブランチ・paths） / キャッシュ | 必ず対応 |
| 2 | ARM ランナー / Vitest の `isolate: false` / テストの並列化 | ユーザーに確認せず検証し、効果があれば適用 |
| 3 | Draft PR のスキップ / CI 本体を `ubuntu-slim` に / デフォルトブランチへの push もキャンセル対象にする | ユーザーが選択したものを検証し、効果があれば適用 |

- **Tier 2** は、効果を CI の計測で判断でき、代償（速さや技術的なリスク）を計測と PR のレビューで確認できる施策です。変更が大きくなる場合（例：並列化のために DB をワーカーごとに分ける仕組みが要る）は、実装せず「要相談」として報告します。
- **Tier 3** は、計測では良し悪しを決められず、開発体験や運用方針（Draft 中に CI の結果が見えない、待ち時間が延びる、未検証のコミットが残る）とのトレードオフになる施策です。

各施策の効果・リスク・判断基準は [`skills/private-actions-cost-reduction/references/measures.md`](skills/private-actions-cost-reduction/references/measures.md) にまとめています。

## 必要なもの

- `gh` CLI（認証済み）と、対象リポジトリへの push 権限
- `git`、`bash`、`awk`（JSON の処理は `gh api --jq` で行うため、`jq` は不要）

`gh repo view` など GraphQL を使うコマンドは使わず、REST API（`gh api`）だけで動くようにしています。

## 構成

```
private-actions-cost-reduction/
├── .claude-plugin/
│   └── plugin.json
├── skills/
│   ├── workflow-tier0-rules/
│   │   └── SKILL.md                 # .github/workflows/* を扱うときに読み込まれるルール
│   └── private-actions-cost-reduction/
│       ├── SKILL.md                 # /private-actions-cost-reduction の手順
│       ├── references/
│       │   └── measures.md          # 施策ごとの効果・リスク・判断基準・料金
│       └── scripts/
│           └── measure.sh           # 実行時間・課金分数・費用の集計
└── README.md
```

## 注意事項

- 料金（単価）は変更されることがあります。`measure.sh` と `measures.md` の単価は目安で、計測時に公式ドキュメントで確認するよう指示しています。
- 検証のため、PR のブランチに空コミットを push して CI を複数回実行します。そのぶんの実行時間が課金されます。マージ時に squash すれば、空コミットは履歴に残りません。
- `workflow-tier0-rules` は、Claude の作業ディレクトリから見た `.github/workflows/` 配下のファイルを扱うときに読み込まれます。リポジトリのルート以外で作業している場合は読み込まれないことがあります。
- 費用の計算は Linux の GitHub ホスト型ランナーだけに対応しています。self-hosted、Windows、macOS のランナーは費用を `?` と表示します。
