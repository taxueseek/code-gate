#!/usr/bin/env python3
"""verify_release.py — 发布前确定性校验（stdlib only，无网络）。

检查项：
1. VERSION 是合法语义化版本，且与插件清单、README 版本徽章一致。
2. 每个 skills/*/SKILL.md 的 frontmatter 合法：name 与目录同名、description 与 when_to_use 非空。
3. 插件清单里每个 source 指向真实存在的技能目录（含 SKILL.md）。
4. README 的仓内相对链接全部可达。
5. 对外发布文本不含本机绝对路径、邮箱、私钥或密钥形状的串。
6. 分发的 shell 脚本可执行位不丢。
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ERRORS: list[str] = []
NOTES: list[str] = []

SEMVER = re.compile(r"^\d+\.\d+\.\d+$")


def err(msg: str) -> None:
    ERRORS.append(msg)


def rel(p: Path) -> str:
    try:
        return str(p.relative_to(ROOT))
    except ValueError:
        return str(p)


def read_frontmatter(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---\n"):
        err(f"{rel(path)}: frontmatter 缺失（文件未以 --- 开头）")
        return {}
    end = text.find("\n---", 4)
    if end == -1:
        err(f"{rel(path)}: frontmatter 未闭合")
        return {}
    fields: dict[str, str] = {}
    for line in text[4:end].splitlines():
        m = re.match(r"^([A-Za-z_][\w-]*):\s*(.*)$", line)
        if not m:
            continue
        key, value = m.group(1), m.group(2).strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        fields[key] = value
    return fields


def check_version() -> str:
    version_file = ROOT / "VERSION"
    if not version_file.is_file():
        err("VERSION 缺失")
        return ""
    version = version_file.read_text(encoding="utf-8").strip()
    if not SEMVER.match(version):
        err(f"VERSION 不是语义化版本: {version!r}")
    return version


def check_skills() -> list[Path]:
    skills_dir = ROOT / "skills"
    if not skills_dir.is_dir():
        err("skills/ 目录缺失")
        return []
    skill_dirs = sorted(p for p in skills_dir.iterdir() if p.is_dir())
    if not skill_dirs:
        err("skills/ 下没有任何技能目录")
    for d in skill_dirs:
        skill_md = d / "SKILL.md"
        if not skill_md.is_file():
            err(f"{rel(d)}/SKILL.md 缺失")
            continue
        fm = read_frontmatter(skill_md)
        name = fm.get("name", "")
        if name != d.name:
            err(f"{rel(skill_md)}: name={name!r} 与目录名 {d.name!r} 不一致")
        desc = fm.get("description", "")
        if not desc:
            err(f"{rel(skill_md)}: description 为空")
        elif len(desc) > 1024:
            err(f"{rel(skill_md)}: description 超过 1024 字符（{len(desc)}）")
        if not fm.get("when_to_use"):
            err(f"{rel(skill_md)}: when_to_use 为空")
        for key in ("name", "description", "when_to_use", "dispatch_intent"):
            if key not in fm:
                NOTES.append(f"{rel(skill_md)}: frontmatter 未定义 {key}")
    return skill_dirs


def check_marketplace(version: str) -> None:
    path = ROOT / ".claude-plugin" / "marketplace.json"
    if not path.is_file():
        err(".claude-plugin/marketplace.json 缺失")
        return
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        err(f"{rel(path)}: JSON 解析失败: {exc}")
        return
    plugins = data.get("plugins")
    if not isinstance(plugins, list) or not plugins:
        err(f"{rel(path)}: plugins 为空")
        return
    names = set()
    for entry in plugins:
        name = entry.get("name", "")
        if not name:
            err(f"{rel(path)}: 存在缺少 name 的插件条目")
            continue
        if name in names:
            err(f"{rel(path)}: 插件名重复 {name!r}")
        names.add(name)
        if entry.get("version") != version:
            err(f"{rel(path)}: {name} version={entry.get('version')!r} 与 VERSION {version!r} 不一致")
        source = entry.get("source", "")
        source_path = (ROOT / source.lstrip("./")).resolve() if source else None
        if not source_path or not source_path.is_dir():
            err(f"{rel(path)}: {name} 的 source {source!r} 不是真实目录")
        elif not (source_path / "SKILL.md").is_file():
            err(f"{rel(path)}: {name} 的 source {source!r} 下没有 SKILL.md")
        if not entry.get("description"):
            err(f"{rel(path)}: {name} 缺少 description")
    for entry in plugins:
        source = entry.get("source", "")
        if source.startswith("./skills/"):
            NOTES.append(f"插件 {entry.get('name')} 直接指向技能目录 {source}")


LINK = re.compile(r"\[[^\]]*\]\(([^)]+)\)")


def check_readme_links() -> None:
    for name in ("README.md", "README_EN.md", "SCOPE.md", "AGENTS.md", "llms.txt"):
        path = ROOT / name
        if not path.is_file():
            err(f"{name} 缺失")
            continue
        for target in LINK.findall(path.read_text(encoding="utf-8")):
            target = target.split("#", 1)[0].strip()
            if not target or "://" in target or target.startswith(("mailto:", "#")):
                continue
            if not (ROOT / target).exists():
                err(f"{name}: 仓内链接不可达 -> {target}")


# 发布文本里不该出现的形状：本机绝对路径、邮箱、私钥与密钥串
FORBIDDEN = [
    (re.compile(r"/Users/[A-Za-z0-9._-]+"), "本机 macOS 家目录路径"),
    (re.compile(r"/home/[A-Za-z0-9._-]+"), "本机 Linux 家目录路径"),
    (re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"), "邮箱地址"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "私钥"),
    (re.compile(r"\b(?:gho|ghp|ghs|github_pat)_[A-Za-z0-9_]{10,}"), "GitHub 令牌"),
    (re.compile(r"\bsk-[A-Za-z0-9]{16,}"), "API Key"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "AWS Access Key"),
    # 内网主机名形状：小写主机名标签 + .local（不误伤 CLAUDE.local.md 这类文件名）
    (re.compile(r"\b[a-z][a-z0-9-]*\.local\b(?!\.)"), "内网主机名"),
]

# 扫描器自身必然包含上面的模式字面量，跳过它自己
SELF_EXEMPT = {"scripts/verify_release.py"}

TEXT_SUFFIXES = {".md", ".txt", ".sh", ".py", ".json", ".yml", ".yaml", ".svg", ".gitattributes", ".gitignore"}
ALLOWED = {
    "users.noreply.github.com",  # 公开的 noreply 域名，不是可回信邮箱
}


def check_public_text() -> None:
    for path in sorted(ROOT.rglob("*")):
        if not path.is_file() or ".git/" in rel(path):
            continue
        if rel(path) in SELF_EXEMPT:
            continue
        if path.name not in {".gitignore", ".gitattributes"} and path.suffix not in TEXT_SUFFIXES:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for pattern, label in FORBIDDEN:
            for hit in pattern.findall(text):
                if any(a in hit for a in ALLOWED):
                    continue
                err(f"{rel(path)}: 命中{label}: {hit}")


def check_script_bits() -> None:
    for path in sorted((ROOT / "skills").rglob("*.sh")) + sorted((ROOT / "tests").rglob("*.sh")):
        if not path.stat().st_mode & 0o111:
            err(f"{rel(path)}: 分发脚本缺少可执行位")


def check_version_badge(version: str) -> None:
    """README 用动态版本徽章时不含字面版本号；两者有其一即可。"""
    if not version:
        return
    readme = ROOT / "README.md"
    text = readme.read_text(encoding="utf-8") if readme.is_file() else ""
    if version in text or "img.shields.io/github/v/tag/" in text:
        return
    NOTES.append(f"README.md 未出现版本号 {version}，也没有动态版本徽章")


def main() -> int:
    version = check_version()
    check_skills()
    check_marketplace(version)
    check_readme_links()
    check_public_text()
    check_script_bits()
    check_version_badge(version)

    for note in NOTES:
        print(f"note:  {note}")
    for error in ERRORS:
        print(f"error: {error}")
    if ERRORS:
        print(f"\nverify_release: FAILED ({len(ERRORS)} error(s))")
        return 1
    print(f"\nverify_release: ok (version {version}, {len(NOTES)} note(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
