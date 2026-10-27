#!/bin/bash
# Shared, read-only selection of the exact OS build carried by a native package.
# Compatible with the macOS system Bash 3.2; does not change preferences or files.

lpr_profile_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

lpr_profile_error() {
    echo "原生启动台版本选择失败: $*" >&2
    return 1
}

lpr_select_package_profile() {
    local lpr_manifest="${1:-}" lpr_product lpr_build lpr_arch lpr_format
    local lpr_expected_sha lpr_expected_info lpr_prefix
    [ -f "$lpr_manifest" ] && [ ! -L "$lpr_manifest" ] \
        || { lpr_profile_error "安装包清单缺失或不是普通文件"; return 1; }
    plutil -lint "$lpr_manifest" >/dev/null \
        || { lpr_profile_error "安装包清单无法解析"; return 1; }
    lpr_product="$(sw_vers -productVersion)" || return 1
    lpr_build="$(sw_vers -buildVersion)" || return 1
    lpr_arch="$(uname -m)" || return 1
    [ "$lpr_arch" = x86_64 ] \
        || { lpr_profile_error "仅支持 Intel / x86_64"; return 1; }
    case "$lpr_product/$lpr_build" in
        26.7.1/25G241)
            lpr_expected_sha=278ed95b86bdef7e122820a0251c5a607fec377c217fae34a651397e8082e193
            lpr_expected_info=df5a816eb4136b81c281ecbc4fe910cf82fbc572268219ae950c569a3ac5c2ab
            ;;
        26.7.2/25G332)
            lpr_expected_sha=0e13feca187548ea9a1e1c90c69a3a011133d919be7e0d6ad56da5cd46b2ecc2
            lpr_expected_info=13ee6ebf392c4c8b86b8a70f8cbe782ac12426f35543ee89fdb6f3f1262fe06c
            ;;
        *) lpr_profile_error "不支持 macOS $lpr_product ($lpr_build)"; return 1 ;;
    esac
    PROFILE_ARCH="$(lpr_profile_value "$lpr_manifest" SupportedArchitecture)"
    [ "$PROFILE_ARCH" = "$lpr_arch" ] \
        || { lpr_profile_error "包内架构不匹配"; return 1; }
    [ "$(lpr_profile_value "$lpr_manifest" DockVersion)" = 2427.6 ] \
        || { lpr_profile_error "包内 Dock 版本不匹配"; return 1; }
    lpr_format="$(lpr_profile_value "$lpr_manifest" FormatVersion)"
    case "$lpr_format" in
        2)
            lpr_prefix="Variants:$lpr_build"
            PROFILE_PRODUCT="$(lpr_profile_value "$lpr_manifest" "$lpr_prefix:ProductVersion")"
            PROFILE_BUILD="$(lpr_profile_value "$lpr_manifest" "$lpr_prefix:BuildVersion")"
            PROFILE_STOCK_SHA="$(lpr_profile_value "$lpr_manifest" "$lpr_prefix:StockSourceSHA256")"
            PROFILE_STOCK_INFO_SHA="$(lpr_profile_value "$lpr_manifest" "$lpr_prefix:StockInfoPlistSHA256")"
            PROFILE_CANDIDATE_SHA="$(lpr_profile_value "$lpr_manifest" "$lpr_prefix:CandidateSHA256")"
            PROFILE_EXPERIMENT="$(lpr_profile_value "$lpr_manifest" "$lpr_prefix:DockExperimentVersion")"
            PROFILE_VARIANT_DIR="$(lpr_profile_value "$lpr_manifest" "$lpr_prefix:RelativeDirectory")"
            [ "$PROFILE_VARIANT_DIR" = "variants/$lpr_build" ] \
                || { lpr_profile_error "包内版本目录不匹配"; return 1; }
            ;;
        1)
            PROFILE_PRODUCT="$(lpr_profile_value "$lpr_manifest" SupportedProductVersion)"
            PROFILE_BUILD="$(lpr_profile_value "$lpr_manifest" SupportedBuildVersion)"
            PROFILE_STOCK_SHA="$(lpr_profile_value "$lpr_manifest" StockSourceSHA256)"
            PROFILE_STOCK_INFO_SHA="$lpr_expected_info"
            PROFILE_CANDIDATE_SHA="$(lpr_profile_value "$lpr_manifest" CandidateSHA256)"
            PROFILE_EXPERIMENT="$(lpr_profile_value "$lpr_manifest" DockExperimentVersion)"
            PROFILE_VARIANT_DIR=.
            ;;
        *) lpr_profile_error "不支持清单格式 $lpr_format"; return 1 ;;
    esac
    [ "$PROFILE_PRODUCT" = "$lpr_product" ] && [ "$PROFILE_BUILD" = "$lpr_build" ] \
        || { lpr_profile_error "包内没有当前系统对应的 Dock"; return 1; }
    [ "$PROFILE_STOCK_SHA" = "$lpr_expected_sha" ] \
        && [ "$PROFILE_STOCK_INFO_SHA" = "$lpr_expected_info" ] \
        || { lpr_profile_error "包内原版来源与系统 build 不匹配"; return 1; }
    [[ "$PROFILE_CANDIDATE_SHA" =~ ^[0-9a-f]{64}$ ]] \
        || { lpr_profile_error "候选 Dock 哈希格式无效"; return 1; }
    [ "$PROFILE_EXPERIMENT" = 2427.6.9 ] \
        || { lpr_profile_error "未知的原生补丁版本"; return 1; }
    PROFILE_PACKAGE_VERSION="$(lpr_profile_value "$lpr_manifest" PackageVersion)"
    return 0
}
