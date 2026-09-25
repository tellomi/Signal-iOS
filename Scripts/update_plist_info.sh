#!/bin/sh

set -e

# PROJECT_DIR will be set when run from xcode, else we infer it
if [ "${PROJECT_DIR}" = "" ]; then
    PROJECT_DIR=`git rev-parse --show-toplevel`
    echo "inferred ${PROJECT_DIR}"
fi

# Capture project hashes that we want to add to the Info.plist
cd $PROJECT_DIR
_git_commit_signal=`git log --pretty=oneline --decorate=no | head -1`

# Remove existing .plist entry, if any.
/usr/libexec/PlistBuddy -c "Delete BuildDetails" Signal/Signal-Info.plist || true
# Add new .plist entry.
/usr/libexec/PlistBuddy -c "add BuildDetails dict" Signal/Signal-Info.plist

echo "CONFIGURATION: ${CONFIGURATION}"
# Tellomi（tellomi/tellomi#1142，需求第 3.6 节）：构建兜底过期要三端都生效。上游只在 App Store Release 写构建时间，
# Testable Release（给测试机装的包）没有时间戳，AppVersion 就把启动时刻当构建时间，永远不过期。
# 和 App Store Release 一样，编完 Testable Release 后这份 Info.plist 会带着 BuildDetails，下次编 Debug 时清空；别提交它。
if [ "${CONFIGURATION}" = "App Store Release" ] || [ "${CONFIGURATION}" = "Testable Release" ]; then
    /usr/libexec/PlistBuddy -c "add :BuildDetails:XCodeVersion string '${XCODE_VERSION_MAJOR}.${XCODE_VERSION_MINOR}'" Signal/Signal-Info.plist
    /usr/libexec/PlistBuddy -c "add :BuildDetails:SignalCommit string '$_git_commit_signal'" Signal/Signal-Info.plist

    # Use UTC
    _build_datetime=`date -u`
    /usr/libexec/PlistBuddy -c "add :BuildDetails:DateTime string '$_build_datetime'" Signal/Signal-Info.plist

    _build_timestamp=`date +%s`
    /usr/libexec/PlistBuddy -c "add :BuildDetails:Timestamp integer $_build_timestamp" Signal/Signal-Info.plist
fi
