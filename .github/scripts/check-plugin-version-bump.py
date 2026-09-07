#!/usr/bin/env python3
"""変更されたプラグインの version が base より増えているかを検証する。"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence


# SemVer の core + pre-release までを扱う。build metadata は比較に使わないが、
# 形式としては許可したいので正規表現では受け付ける。pre-release/build の各識別子は
# "." 区切りで英数字とハイフンのみ・空文字禁止、数値のみの識別子は先頭ゼロ禁止
# (SemVer 2.0.0 の仕様通り)。
_IDENTIFIER = r"(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)"
SEMVER_RE = re.compile(
    r"^(?P<major>0|[1-9]\d*)\.(?P<minor>0|[1-9]\d*)\.(?P<patch>0|[1-9]\d*)"
    rf"(?:-(?P<prerelease>{_IDENTIFIER}(?:\.{_IDENTIFIER})*))?"
    rf"(?:\+(?P<build>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)


class VersionBumpError(Exception):
    pass


@dataclass(frozen=True)
class PluginEntry:
    name: str
    source: str


@dataclass(frozen=True)
class SemVer:
    major: int
    minor: int
    patch: int
    prerelease: tuple[str, ...]

    @classmethod
    def parse(cls, value: str) -> SemVer | None:
        match = SEMVER_RE.fullmatch(value)
        if match is None:
            return None

        prerelease = match.group("prerelease")
        prerelease_parts = tuple(prerelease.split(".")) if prerelease else ()
        return cls(
            major=int(match.group("major")),
            minor=int(match.group("minor")),
            patch=int(match.group("patch")),
            prerelease=prerelease_parts,
        )

    def __lt__(self, other: SemVer) -> bool:
        self_core = (self.major, self.minor, self.patch)
        other_core = (other.major, other.minor, other.patch)
        if self_core != other_core:
            return self_core < other_core

        if not self.prerelease and not other.prerelease:
            return False
        if not self.prerelease:
            return False
        if not other.prerelease:
            return True

        return compare_prerelease(self.prerelease, other.prerelease) < 0


def compare_prerelease(left: Sequence[str], right: Sequence[str]) -> int:
    # SemVer の pre-release 比較規則:
    # - 数値同士は数値比較
    # - 数値識別子は文字列識別子より小さい
    # - ここまで同じなら、要素数が短い方が小さい
    for left_part, right_part in zip(left, right):
        if left_part == right_part:
            continue

        left_numeric = left_part.isdigit()
        right_numeric = right_part.isdigit()
        if left_numeric and right_numeric:
            return -1 if int(left_part) < int(right_part) else 1
        if left_numeric != right_numeric:
            return -1 if left_numeric else 1
        return -1 if left_part < right_part else 1

    if len(left) == len(right):
        return 0
    return -1 if len(left) < len(right) else 1


def run_git(args: Sequence[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        check=check,
        capture_output=True,
        text=True,
    )


def ensure_commit(sha: str) -> None:
    if run_git(["cat-file", "-e", f"{sha}^{{commit}}"], check=False).returncode == 0:
        return

    print(f"{sha} を fetch します")
    # Actions の shallow clone を想定して、まず対象コミットだけを浅く取得する。
    # それでも取れないケースでは通常 fetch にフォールバックする。
    primary_fetch = run_git(["fetch", "--no-tags", "--depth=1", "origin", sha], check=False)
    if primary_fetch.returncode == 0:
        return

    fallback_fetch = run_git(["fetch", "--no-tags", "origin"], check=False)
    if fallback_fetch.returncode != 0:
        raise VersionBumpError(fallback_fetch.stderr.strip() or f"{sha} の fetch に失敗しました")


def changed_files(base_sha: str, head_sha: str) -> set[str]:
    # 3-dot diff で merge-base からの差分だけを見る。2-dot だと base 側に後から
    # 入った変更まで拾ってしまい、古い PR で誤検知しやすい。
    result = run_git(["diff", "--name-only", f"{base_sha}...{head_sha}"])
    return {line for line in result.stdout.splitlines() if line}


def normalize_source(source: str) -> str:
    # marketplace.json は "./plugin-dir/" や "." (リポジトリ直下全体を1プラグイン
    # として扱う表記) のような表記ゆれがありうるため、git diff のパス表記に合わせて
    # 比較しやすい形へ揃える。"." や "./" はリポジトリ直下を表す空文字列にする。
    normalized = source.removeprefix("./").rstrip("/")
    return "" if normalized in ("", ".") else normalized


def load_marketplace_plugins(path: Path) -> list[PluginEntry]:
    try:
        raw_data: Any = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise VersionBumpError(f"error: {path} が見つかりません") from exc

    if not isinstance(raw_data, dict):
        raise VersionBumpError(f"error: {path} の内容が object ではありません")

    plugins_raw = raw_data.get("plugins")
    if not isinstance(plugins_raw, list):
        raise VersionBumpError(f"error: {path} に有効な plugins 配列がありません")

    plugins: list[PluginEntry] = []
    for item in plugins_raw:
        if not isinstance(item, dict):
            raise VersionBumpError(f"error: {path} に不正な plugin エントリが含まれています")

        name = item.get("name")
        source = item.get("source")
        if not isinstance(name, str) or not isinstance(source, str):
            raise VersionBumpError(
                f"error: {path} に name/source が文字列でない plugin エントリが含まれています"
            )

        plugins.append(PluginEntry(name=name, source=normalize_source(source)))

    return plugins


def plugin_has_changes(plugin_source: str, changed_paths: set[str]) -> bool:
    # source が "" (リポジトリ直下全体を1プラグインとする表記) の場合は、
    # 何か1つでも変更があれば対象とする。
    if plugin_source == "":
        return bool(changed_paths)

    prefix = f"{plugin_source}/"
    return any(path.startswith(prefix) for path in changed_paths)


def load_manifest_version_at(sha: str, manifest_path: Path) -> str | None:
    # ワーキングツリーではなく常に git object から読む。pull_request イベントでは
    # actions/checkout がデフォルトでマージコミットをチェックアウトするため、
    # ワーキングツリーの内容は HEAD_SHA (PR ブランチ先頭) の内容と一致するとは
    # 限らない。
    result = run_git(["show", f"{sha}:{manifest_path.as_posix()}"], check=False)
    if result.returncode != 0:
        return None

    try:
        raw_data: Any = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise VersionBumpError(f"error: {sha} の {manifest_path} が不正な JSON です: {exc}") from exc

    if not isinstance(raw_data, dict):
        raise VersionBumpError(f"error: {sha} の {manifest_path} の内容が object ではありません")

    version = raw_data.get("version", "")
    return version if isinstance(version, str) else ""


def validate_plugin(
    entry: PluginEntry, base_sha: str, head_sha: str, changed_paths: set[str]
) -> tuple[int, int]:
    # 変更のないプラグインは version bump 対象外。
    if not plugin_has_changes(entry.source, changed_paths):
        return 0, 0

    manifest_path = Path(entry.source) / ".claude-plugin" / "plugin.json"

    try:
        head_version = load_manifest_version_at(head_sha, manifest_path)
    except VersionBumpError as exc:
        print(str(exc), file=sys.stderr)
        return 1, 0

    if head_version is None:
        print(f"error: plugin '{entry.name}' に {manifest_path} がありません", file=sys.stderr)
        return 1, 0
    if not head_version:
        print(f"error: plugin '{entry.name}' の {manifest_path} に version がありません", file=sys.stderr)
        return 1, 0

    try:
        base_version = load_manifest_version_at(base_sha, manifest_path)
    except VersionBumpError as exc:
        print(str(exc), file=sys.stderr)
        return 1, 0

    # head 側が semver でない場合はエラー。新規プラグイン(base に manifest がない)
    # であってもここは免除しない — でないと新規プラグインの version に不正な文字列
    # を入れても CI が通ってしまう。
    head_semver = SemVer.parse(head_version)
    if head_semver is None:
        print(
            f"error: plugin '{entry.name}' の head version '{head_version}' は正しい semver ではありません",
            file=sys.stderr,
        )
        return 1, 0

    if base_version is None:
        print(
            f"ok: plugin '{entry.name}' は新規プラグインです (base に {manifest_path} がない); "
            f"head version={head_version}"
        )
        return 0, 1

    # base 側が semver でない場合は、機械的に正しく比較できないため、head が semver
    # になっていることをもって bump とみなす (ここで head_version と base_version が
    # 一致することはない: 一致するなら base_version も semver 形式のはずで
    # base_semver is None と矛盾するため)。「無条件でスキップ」ではなく checked に
    # 計上することで、最終サマリが「変更なし」と誤表示されないようにしている。
    base_semver = SemVer.parse(base_version)
    if base_semver is None:
        print(
            f"ok: plugin '{entry.name}' の base version '{base_version}' は semver ではありませんが、"
            f"head version '{head_version}' が正しい semver になっているため bump とみなします"
        )
        return 0, 1

    if not base_semver < head_semver:
        print(
            f"error: plugin '{entry.name}' に変更がありますが version が更新されていません "
            f"(base={base_version} head={head_version})",
            file=sys.stderr,
        )
        return 1, 0

    print(f"ok: plugin '{entry.name}' は {base_version} → {head_version} に bump されました")
    return 0, 1


def main() -> int:
    base_sha = os.environ.get("BASE_SHA")
    if not base_sha:
        print("error: BASE_SHA が必要です", file=sys.stderr)
        return 1

    head_sha = os.environ.get("HEAD_SHA", "HEAD")
    marketplace_path = Path(os.environ.get("MARKETPLACE_JSON", ".claude-plugin/marketplace.json"))

    try:
        plugins = load_marketplace_plugins(marketplace_path)
        ensure_commit(base_sha)
        ensure_commit(head_sha)
        changed_paths = changed_files(base_sha, head_sha)
    except VersionBumpError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except (json.JSONDecodeError, subprocess.CalledProcessError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    errors = 0
    checked = 0
    # 各プラグインごとに「エラー件数」と「実際に version を検証した件数」を集計する。
    for entry in plugins:
        entry_errors, entry_checked = validate_plugin(entry, base_sha, head_sha, changed_paths)
        errors += entry_errors
        checked += entry_checked

    if errors > 0:
        print(f"version bump check failed with {errors} error(s)", file=sys.stderr)
        return 1

    if checked == 0:
        print("変更されたプラグインディレクトリがありません — version bump check をスキップします")
    else:
        print(f"version bump check: OK ({checked} 件のプラグインを検証しました)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
