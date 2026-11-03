---
name: workflow-tier0-rules
description: プライベートリポジトリの GitHub Actions ワークフロー（.github/workflows/*.yml）を作成・編集・レビューするときに必ず守る、実行コストの基本ルール（Tier 0）
paths:
  - ".github/workflows/*.yml"
  - ".github/workflows/*.yaml"
user-invocable: false
---

# GitHub Actions ワークフローの基本ルール（Tier 0）

`.github/workflows/` 配下のワークフローを作成・編集・レビューするときは、以下のルールに従う。

## 適用対象の判定（最初に行う）

このルールが必要なのは **プライベートリポジトリだけ** である。パブリックリポジトリの GitHub ホスト型の標準ランナーは無料のため、このルールを適用しない。

1. リポジトリの公開範囲を確認する。

   ```bash
   repo=$(git remote get-url origin | sed -E 's#^(https://[^/]+/|git@[^:]+:|ssh://git@[^/]+/)##; s#\.git$##')
   gh api "repos/$repo" --jq .visibility
   ```

   `private` または `internal` なら適用する。`public` なら適用しない。（`gh repo view` は GraphQL を使うため、環境によっては動かない。REST API で確認する）
2. `gh` が使えない・認証されていないなどで判定できない場合は、推測せずにユーザーに確認する。
3. パブリックリポジトリでは、ユーザーから明示的に依頼された場合を除き、以下のルールに基づく変更や指摘をしない。

## ルール 1：すべてのジョブに `timeout-minutes` を設定する

GitHub Actions の既定のタイムアウトは 360 分で、ジョブがハングすると最大 6 時間分が課金される。

- `runs-on` で実行するすべてのジョブに `timeout-minutes` を設定する。
- **再利用可能ワークフローを呼び出すジョブ（`jobs.<id>.uses`）には `timeout-minutes` を書かない。** 呼び出しジョブで使えるキーは限られていて（`name` / `uses` / `with` / `secrets` / `strategy` / `needs` / `if` / `permissions` / `concurrency`）、書くとワークフローが構文エラーで起動しなくなる。代わりに、呼び出される側のワークフロー（`on: workflow_call`）のジョブに設定する。呼び出される側が別リポジトリにあり変更できない場合は、その旨を報告する。
- 値は **通常の実行時間の 3〜5 倍** を目安にし、最小でも 5 分とする。通常の実行時間が分からない場合は、直近の実行履歴（`gh run list` / `gh run view`）から確認する。新規ジョブで履歴がない場合は、処理内容から見積もり、根拠をコメントに残す。
- コメントで通常の実行時間を書いておく（例：`# 通常は 2〜3 分で終わる`）。後で実行時間が延びたときに見直せるようにするため。
- `ubuntu-slim` のジョブは 15 分を超えると強制終了される（`timeout-minutes` では延ばせない）。15 分を超える値を設定しない。

## ルール 2：PR で動くワークフローに `concurrency` を設定する

同じ PR に続けて push すると、古いコミットの実行も最後まで課金される。

- `pull_request` で動くワークフローには、ワークフロー単位で次の設定を入れる。

  ```yaml
  concurrency:
    # PR は ref ごとに 1 グループにまとめ、古い実行をキャンセルする。
    # PR 以外（デフォルトブランチへの push など）は実行ごとに別グループにし、すべてのコミットを検証する
    group: ${{ github.workflow }}-${{ github.event_name == 'pull_request' && github.ref || github.run_id }}
    cancel-in-progress: true
  ```

  `cancel-in-progress: false` にするだけでは、全コミットの検証にはならない。同じグループでは実行中のものが 1 件、待機中のものが 1 件までで、新しい実行が来ると **待機中の実行はキャンセルされて置き換えられる**。そのため、連続して push すると途中のコミットが検証されない。PR 以外の実行を `github.run_id` で別グループにすることで、キャンセルも置き換えも起きないようにする。
- `pull_request_target` では `github.ref` がベースブランチを指すため、`group` に PR 番号（`${{ github.event.pull_request.number }}`）を使う。
- **デプロイ・リリース・外部への書き込みを行うワークフローは、実行中のものをキャンセルしない。** `cancel-in-progress: false` にして直列化する。

  ```yaml
  concurrency:
    group: ${{ github.workflow }}
    cancel-in-progress: false
  ```

  この設定でも、待機中の実行は新しい実行に置き換えられるため、連続して push すると途中のコミットはデプロイされず、最新のコミットだけがデプロイされる。すべてのコミットを順番にデプロイする必要があるワークフロー（リリースごとにタグやパッケージを作るものなど）では、この設定を使わず、既存の方式のままにしてユーザーに確認する。

- 既存の `concurrency` がある場合は、上記の方針と矛盾しない限りそのままにする。

## ルール 3：軽いジョブは `ubuntu-slim` を既定にする

`ubuntu-slim` の単価は `ubuntu-latest` の 1/3 である。課金はジョブごとに 1 分単位で切り上げられるため、数秒〜数十秒で終わるジョブは単価の差がそのまま削減になる。

次の条件を **すべて** 満たすジョブは `runs-on: ubuntu-slim` にする。

- 現在、GitHub ホスト型の Linux ランナー（`ubuntu-latest` / `ubuntu-24.04` など）で動いている。Windows・macOS・self-hosted・larger runner のジョブは対象外（OS 固有の機能や、セルフホスト環境だけにあるツール・ネットワーク・認証情報に依存している可能性があるため）
- 数分以内に終わる（ラベル付け、フォーマット、通知、タグ付け、軽い lint など）
- Docker を使わない（`docker` コマンド、`services:`、`container:`、Docker を内部で使うツールを含まない）
- メモリ 5GB で足りる
- CPU を並列で使い切らない
- デプロイ先と同じ CPU アーキテクチャでのビルドを必要としない

再利用可能ワークフローを呼び出すジョブ（`jobs.<id>.uses`）には `runs-on` を書けないため、呼び出される側のジョブで判断する。

1 つでも満たさない、または判断できないジョブは、`ubuntu-slim` にしない（既存のランナーのまま）。重いジョブのランナー変更は、このルールの範囲外とする（`/private-actions-cost-reduction` で検証しながら行う）。

## 既存ワークフローを編集・レビューするとき

- 依頼された変更の範囲内で、上記のルールに違反している箇所に気づいたら、修正するか、修正を提案する。依頼と無関係なワークフローまで一括で書き換えない。
- ルールに従わない理由がある場合（例：意図的にキャンセルしない）は、その理由をワークフローのコメントに残す。
