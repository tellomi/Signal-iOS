#!/usr/bin/env python3
#
# Copyright 2026 重庆半格智能科技有限公司
# SPDX-License-Identifier: AGPL-3.0-only
#
# Tellomi：每次往 TestFlight / App Store 上传之前，把构建号（CFBundleVersion）加 1。
#
# owner 2026-09-25 定 iOS 用 TestFlight 外部测试发给朋友。App Store Connect 要求同一个 App 每次上传的构建号都比上一次大，
# 主 App、通知扩展、分享扩展三份 Info.plist 的 CFBundleVersion 还必须一样。规则：
# - 构建号是一个只增不减的整数。第一次上传用现有的 0.1.0 (0)，之后每上传一次跑一次本脚本；
# - 换版本号（Scripts/bump_build_tag.py 改的是 CFBundleShortVersionString）时构建号不归零；
# - 三份 plist 不一致时拒绝改，先查清楚是哪一次漏了。
#
# 用法（在仓库根目录）：
#   Scripts/tellomi_bump_build_number.py              改三份 plist 并提交「Bump build number to N」
#   Scripts/tellomi_bump_build_number.py --no-commit  只改文件
#   Scripts/tellomi_bump_build_number.py --check      只核对三份一致并打印当前构建号

import argparse
import os
import plistlib
import subprocess
import sys

INFO_PLIST_PATHS = [
    "Signal/Signal-Info.plist",
    "SignalShareExtension/Info.plist",
    "SignalNSE/Info.plist",
]


def read_build_numbers(root):
    numbers = {}
    for path in INFO_PLIST_PATHS:
        with open(os.path.join(root, path), "rb") as file:
            value = plistlib.load(file)["CFBundleVersion"]
        if not value.isdigit():
            sys.exit(f"{path}: CFBundleVersion is {value!r}, expected a plain integer")
        numbers[path] = int(value)
    return numbers


def write_build_number(root, path, number):
    full_path = os.path.join(root, path)
    with open(full_path, "rb") as file:
        contents = plistlib.load(file)
    contents["CFBundleVersion"] = str(number)
    with open(full_path, "wb") as file:
        plistlib.dump(contents, file)


def main():
    parser = argparse.ArgumentParser(description="Tellomi: bump CFBundleVersion by one in all three Info.plists")
    parser.add_argument("--no-commit", action="store_true", help="change the files but don't commit")
    parser.add_argument("--check", action="store_true", help="only check that the three plists agree and print the build number")
    parser.add_argument("--root", default=".", help="repository root (default: current directory)")
    ns = parser.parse_args()

    numbers = read_build_numbers(ns.root)
    if len(set(numbers.values())) != 1:
        for path, number in numbers.items():
            print(f"{number}\t{path}")
        sys.exit("CFBundleVersion differs between the Info.plists; fix that before bumping")
    current = next(iter(numbers.values()))

    if ns.check:
        print(current)
        return

    if not ns.no_commit:
        status = subprocess.run(["git", "-C", ns.root, "status", "--porcelain", "--", *INFO_PLIST_PATHS], check=True, capture_output=True, encoding="utf8").stdout
        if status.strip():
            print(status)
            sys.exit("The Info.plists have uncommitted changes (a Testable Release build rewrites Signal-Info.plist; restore it first)")

    new = current + 1
    for path in INFO_PLIST_PATHS:
        write_build_number(ns.root, path, new)
    print(f"CFBundleVersion {current} -> {new}")

    if not ns.no_commit:
        subprocess.run(["git", "-C", ns.root, "add", "--", *INFO_PLIST_PATHS], check=True)
        subprocess.run(["git", "-C", ns.root, "commit", "-m", f"Bump build number to {new}"], check=True)


if __name__ == "__main__":
    main()
