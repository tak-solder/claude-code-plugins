#!/usr/bin/env bash
# GitHub Actions のジョブ実行時間と、課金分数・費用（目安）を集計する。
#
# 使い方:
#   measure.sh usage [days]                        直近 days 日（既定 30）のワークフロー別の実行回数・課金分数・費用
#   measure.sh baseline <workflow> [branch] [n]    指定ブランチ（既定: デフォルトブランチ）の直近 n 回（既定 5）の成功した実行
#   measure.sh sha <commit-sha> [workflow]         指定コミットで動いた実行
#
# <workflow> はワークフローのファイル名（例: ci.yml）。
# 単価はランナーのラベルから推定する（ubuntu-slim: $0.002 / *-arm: $0.005 / その他の ubuntu: $0.006）。
# それ以外のランナー（self-hosted、Windows、macOS など）は費用を "?" と表示する。
# 課金分数はジョブごとに 1 分単位で切り上げる。
set -euo pipefail

# 対象リポジトリ（owner/repo）。GH_REPO があればそれを使い、なければ origin のリモート URL から求める
# （gh repo view は GraphQL を使うため、REST API だけで完結させる）
if [ -n "${GH_REPO:-}" ]; then
  REPO="$GH_REPO"
else
  REPO=$(git remote get-url origin | sed -E 's#^(https://[^/]+/|git@[^:]+:|ssh://git@[^/]+/)##; s#\.git$##')
fi
default_branch() { gh api "repos/$REPO" --jq .default_branch; }

# ジョブ一覧を TSV（workflow, job, seconds, label, conclusion, run_id）で出力する
jobs_of_run() {
  gh api "repos/$REPO/actions/runs/$1/jobs?per_page=100" --jq '
    .jobs[]
    | select(.started_at != null and .completed_at != null)
    | [.workflow_name, .name,
       (((.completed_at | fromdate) - (.started_at | fromdate)) | tostring),
       (.labels | join(",")), (.conclusion // ""), (.run_id | tostring)]
    | @tsv'
}

# TSV に課金分数と費用を付けて表示し、ジョブ別の平均を出す
summarize() {
  awk -F'\t' '
    function price(label) {
      if (label ~ /slim/) return 0.002
      if (label ~ /-arm/) return 0.005
      if (label ~ /^ubuntu/) return 0.006
      return -1
    }
    {
      sec = $3 + 0; min = int((sec + 59) / 60); if (min < 1) min = 1
      p = price($4); cost = (p < 0) ? "?" : sprintf("$%.4f", min * p)
      printf "%s\t%s\t%ds\t%dmin\t%s\t%s\t%s\trun:%s\n", $1, $2, sec, min, cost, $4, $5, $6
      k = $1 " / " $2 " [" $4 "]"
      n[k]++; s[k] += sec; m[k] += min
      if (p >= 0) c[k] += min * p; else unk[k] = 1
    }
    END {
      print ""
      print "== ジョブ別の平均 =="
      for (k in n) {
        cost = (k in unk) ? "?" : sprintf("$%.4f", c[k] / n[k])
        printf "%s\t回数=%d\t平均=%.0fs\t平均課金=%.2fmin\t平均費用=%s\n", k, n[k], s[k] / n[k], m[k] / n[k], cost
      }
    }'
}

cmd="${1:-}"
case "$cmd" in
  usage)
    days="${2:-30}"
    since=$(date -u -d "-${days} days" +%Y-%m-%d 2>/dev/null || date -u -v-"${days}"d +%Y-%m-%d)
    tmp=$(mktemp)
    page=1
    while :; do
      ids=$(gh api "repos/$REPO/actions/runs?per_page=100&page=$page&created=>=$since" --jq '.workflow_runs[].id')
      [ -z "$ids" ] && break
      for id in $ids; do jobs_of_run "$id" >> "$tmp"; done
      page=$((page + 1))
    done
    echo "対象: $REPO（$since 以降）"
    awk -F'\t' '
      function price(label) {
        if (label ~ /slim/) return 0.002
        if (label ~ /-arm/) return 0.005
        if (label ~ /^ubuntu/) return 0.006
        return -1
      }
      {
        sec = $3 + 0; min = int((sec + 59) / 60); if (min < 1) min = 1
        k = $1 " / " $2 " [" $4 "]"; n[k]++; m[k] += min; s[k] += sec
        p = price($4); if (p >= 0) c[k] += min * p; else unk[k] = 1
      }
      END {
        for (k in n) {
          cost = (k in unk) ? "?" : sprintf("$%.2f", c[k])
          printf "%s\t回数=%d\t平均=%.0fs\t課金合計=%dmin\t費用合計=%s\n", k, n[k], s[k] / n[k], m[k], cost
        }
      }' "$tmp" | sort -t$'\t' -k4 -r
    rm -f "$tmp"
    ;;
  baseline)
    wf="${2:?ワークフローのファイル名を指定してください}"
    branch="${3:-$(default_branch)}"
    n="${4:-5}"
    ids=$(gh api "repos/$REPO/actions/workflows/$wf/runs?branch=$branch&status=success&per_page=$n" --jq '.workflow_runs[].id')
    [ -z "$ids" ] && { echo "成功した実行が見つかりません: $wf ($branch)" >&2; exit 1; }
    for id in $ids; do jobs_of_run "$id"; done | summarize
    ;;
  sha)
    sha="${2:?コミット SHA を指定してください}"
    wf="${3:-}"
    filter='.workflow_runs[]'
    [ -n "$wf" ] && filter=".workflow_runs[] | select(.path | endswith(\"/$wf\"))"
    runs=$(gh api "repos/$REPO/actions/runs?head_sha=$sha&per_page=100" --jq "$filter | \"\(.id) \(.status)\"")
    [ -z "$runs" ] && { echo "実行が見つかりません: $sha" >&2; exit 1; }
    if echo "$runs" | grep -qv ' completed$'; then
      echo "未完了の実行があります。完了してから再実行してください:" >&2
      echo "$runs" | grep -v ' completed$' >&2
      exit 2
    fi
    for id in $(echo "$runs" | cut -d' ' -f1); do jobs_of_run "$id"; done | summarize
    ;;
  *)
    sed -n '2,12p' "$0"
    exit 1
    ;;
esac
