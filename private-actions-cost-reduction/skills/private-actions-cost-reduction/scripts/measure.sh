#!/usr/bin/env bash
# GitHub Actions のジョブ実行時間と、課金分数・費用（目安）を集計する。
#
# 使い方:
#   measure.sh usage [days]                        直近 days 日（既定 30）のワークフロー別の実行回数・課金分数・費用
#   measure.sh baseline <workflow> [branch] [n]    指定ブランチ（既定: デフォルトブランチ）の直近 n 回（既定 5、最大 100）の成功した実行
#   measure.sh sha <commit-sha> [workflow]         指定コミットで動いた実行（workflow を省略すると全ワークフロー）
#
# <workflow> はワークフローのファイル名（例: ci.yml）。
# 単価は GitHub ホスト型の Linux ランナーのラベルから推定する（ubuntu-slim: $0.002 / ubuntu-*-arm: $0.005 / その他の ubuntu-*: $0.006）。
# それ以外のランナー（self-hosted、Windows、macOS、ラベル名を付けた larger runner など）は費用を "?" と表示する。
# 課金分数はジョブごとに 1 分単位で切り上げる。
# 再実行（re-run）した実行は、前の試行（attempt）のジョブも課金対象として集計する（列 run#attempt で区別できる）。
# 実行一覧の検索が API の上限（1 検索 1,000 件）を超える場合は、不完全な結果を出さずに終了する（終了コード 3）。
set -euo pipefail

# 対象リポジトリ（owner/repo）。GH_REPO があればそれを使い、なければ origin のリモート URL から求める
# （gh repo view は GraphQL を使うため、REST API だけで完結させる）
if [ -n "${GH_REPO:-}" ]; then
  REPO="$GH_REPO"
else
  REPO=$(git remote get-url origin | sed -E 's#^(https://[^/]+/|git@[^:]+:|ssh://git@[^/]+/)##; s#\.git$##')
fi
default_branch() { gh api "repos/$REPO" --jq .default_branch; }

PER_PAGE="${MEASURE_PER_PAGE:-100}"  # MEASURE_PER_PAGE はページ送りの動作確認用
SEARCH_LIMIT="${MEASURE_SEARCH_LIMIT:-1000}"  # 実行一覧の検索で取得できる上限件数（MEASURE_SEARCH_LIMIT は動作確認用）

# ランナーのラベル（カンマ区切り）から 1 分あたりの単価を返す awk 関数。不明なら -1
PRICE_AWK='
  function price(label) {
    if (label ~ /(^|,)self-hosted(,|$)/) return -1
    if (label !~ /^ubuntu-[^,]*$/) return -1
    if (label == "ubuntu-slim") return 0.002
    if (label ~ /-arm$/) return 0.005
    return 0.006
  }
'

# 実行一覧を検索し、"id<TAB>status<TAB>path" を出力する。$1 はクエリ文字列（例: head_sha=...）。
# 全ページを取得する。検索結果が上限を超える場合は終了コード 3 で終了する。
list_runs() {
  local query="$1" page=1 out total
  while :; do
    out=$(gh api "repos/$REPO/actions/runs?$query&per_page=$PER_PAGE&page=$page" --jq '
      "#TOTAL\t\(.total_count)",
      (.workflow_runs[] | [(.id | tostring), .status, .path] | @tsv)')
    total=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "#TOTAL" { print $2 }')
    if [ "${total:-0}" -gt "$SEARCH_LIMIT" ]; then
      echo "実行一覧の検索結果が上限（$SEARCH_LIMIT 件）を超えています（$query: $total 件）。期間などを絞ってください。" >&2
      exit 3
    fi
    printf '%s\n' "$out" | grep -v '^#TOTAL' || true
    [ $((page * PER_PAGE)) -ge "${total:-0}" ] && break
    page=$((page + 1))
  done
}

# ジョブ一覧を TSV（workflow, job, seconds, label, conclusion, run_id#attempt）で出力する。
# - filter=all で再実行前の試行（attempt）のジョブも含める（どの試行も課金されるため）
# - 大きなマトリクスでも漏れないよう全ページを取得する
#   （--paginate は環境によって Link ヘッダの URL を辿れないことがあるため、page を自前で進める）
jobs_of_run() {
  local page=1 out total
  while :; do
    out=$(gh api "repos/$REPO/actions/runs/$1/jobs?filter=all&per_page=$PER_PAGE&page=$page" --jq '
      "#TOTAL\t\(.total_count)",
      (.jobs[]
        | select(.started_at != null and .completed_at != null)
        | [.workflow_name, .name,
           (((.completed_at | fromdate) - (.started_at | fromdate)) | tostring),
           (.labels | join(",")), (.conclusion // ""), "\(.run_id)#\(.run_attempt // 1)"]
        | @tsv)')
    total=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "#TOTAL" { print $2 }')
    printf '%s\n' "$out" | grep -v '^#TOTAL' || true
    [ $((page * PER_PAGE)) -ge "${total:-0}" ] && break
    page=$((page + 1))
  done
}

# TSV に課金分数と費用を付けて表示し、ジョブ別の平均を出す
summarize() {
  awk -F'\t' "$PRICE_AWK"'
    {
      sec = $3 + 0; min = int((sec + 59) / 60); if (min < 1) min = 1
      p = price($4); cost = (p < 0) ? "?" : sprintf("$%.4f", min * p)
      printf "%s\t%s\t%ds\t%dmin\t%s\t%s\t%s\trun#attempt:%s\n", $1, $2, sec, min, cost, $4, $5, $6
      k = $1 " / " $2 " [" $4 "]"
      n[k]++; s[k] += sec; m[k] += min
      if (p >= 0) c[k] += min * p; else unk[k] = 1
      tm += min; if (p >= 0) tc += min * p; else tunk = 1
    }
    END {
      print ""
      print "== ジョブ別の平均 =="
      for (k in n) {
        cost = (k in unk) ? "?" : sprintf("$%.4f", c[k] / n[k])
        printf "%s\t回数=%d\t平均=%.0fs\t平均課金=%.2fmin\t平均費用=%s\n", k, n[k], s[k] / n[k], m[k] / n[k], cost
      }
      printf "\n== 合計 ==\n課金=%dmin\t費用=%s\n", tm, (tunk ? sprintf("$%.4f + ?", tc) : sprintf("$%.4f", tc))
    }'
}

cmd="${1:-}"
case "$cmd" in
  usage)
    days="${2:-30}"
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    # 1 検索 1,000 件の上限に当たりにくいよう、1 日ずつ検索する（1 日で上限を超える場合は終了する）
    for i in $(seq "$days" -1 0); do
      day=$(date -u -d "-${i} days" +%Y-%m-%d 2>/dev/null || date -u -v-"${i}"d +%Y-%m-%d)
      for id in $(list_runs "created=$day" | cut -f1); do jobs_of_run "$id" >> "$tmp"; done
    done
    since=$(date -u -d "-${days} days" +%Y-%m-%d 2>/dev/null || date -u -v-"${days}"d +%Y-%m-%d)
    echo "対象: $REPO（$since 以降）"
    awk -F'\t' "$PRICE_AWK"'
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
    runs=$(list_runs "head_sha=$sha" | awk -F'\t' -v wf="/$wf" 'wf == "/" || substr($3, length($3) - length(wf) + 1) == wf')
    [ -z "$runs" ] && { echo "実行が見つかりません: $sha ${wf}" >&2; exit 1; }
    if printf '%s\n' "$runs" | awk -F'\t' '$2 != "completed"' | grep -q .; then
      echo "未完了の実行があります。完了してから再実行してください:" >&2
      printf '%s\n' "$runs" | awk -F'\t' '$2 != "completed"' >&2
      exit 2
    fi
    for id in $(printf '%s\n' "$runs" | cut -f1); do jobs_of_run "$id"; done | summarize
    ;;
  *)
    sed -n '2,15p' "$0"
    exit 1
    ;;
esac
