#!/bin/bash
# Shared, read-only selection of the native package profile for the running OS.
# Compatible with the macOS system Bash 3.2; does not change preferences or files.
#
# Policy: any Intel macOS 26.0 or newer may install, as long as its Dock is
# still 2427.6 (the caller checks that). A variant matching the running build
# exactly is preferred; otherwise the manifest's FallbackVariant supplies the
# patched Dock and the target keeps its own per-build backup directory.

lpr_profile_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

lpr_profile_error() {
    echo "原生启动台版本选择失败: $*" >&2
    return 1
}

lpr_version_at_least() {
    local lpr_have="$1" lpr_need="$2" lpr_h_major lpr_h_minor lpr_n_major lpr_n_minor
    lpr_h_major="${lpr_have%%.*}"
    lpr_h_minor="${lpr_have#*.}"
    lpr_h_minor="${lpr_h_minor%%.*}"
    lpr_n_major="${lpr_need%%.*}"
    lpr_n_minor="${lpr_need#*.}"
    lpr_n_minor="${lpr_n_minor%%.*}"
    [ -n "$lpr_h_major" ] && [ -n "$lpr_n_major" ] || return 1
    [ -n "$lpr_h_minor" ] || lpr_h_minor=0
    [ -n "$lpr_n_minor" ] || lpr_n_minor=0
    lpr_h_major=$((10#$lpr_h_major))
    lpr_h_minor=$((10#$lpr_h_minor))
    lpr_n_major=$((10#$lpr_n_major))
    lpr_n_minor=$((10#$lpr_n_minor))
    [ "$lpr_h_major" -gt "$lpr_n_major" ] && return 0
    [ "$lpr_h_major" -lt "$lpr_n_major" ] && return 1
    [ "$lpr_h_minor" -ge "$lpr_n_minor" ]
}

lpr_select_package_profile() {
    local lpr_manifest="${1:-}" lpr_product lpr_build lpr_arch lpr_format
    local lpr_minimum lpr_prefix lpr_fallback lpr_supported_build lpr_supported_product
    [ -f "$lpr_manifest" ] && [ ! -L "$lpr_manifest" ] \
        || { lpr_profile_error "安装包清单缺失或不是普通文件"; return 1; }
    plutil -lint "$lpr_manifest" >/dev/null \
        || { lpr_profile_error "安装包清单无法解析"; return 1; }
    lpr_product="$(sw_vers -productVersion)" || return 1
    lpr_build="$(sw_vers -buildVersion)" || return 1
    lpr_arch="$(uname -m)" || return 1
    [ "$lpr_arch" = x86_64 ] \
        || { lpr_profile_error "仅支持 Intel / x86_64"; return 1; }
    lpr_minimum="$(lpr_profile_value "$lpr_manifest" MinimumProductVersion)"
    [ -n "$lpr_minimum" ] || lpr_minimum=26.0
    lpr_version_at_least "$lpr_product" "$lpr_minimum" \
        || { lpr_profile_error "需要 macOS $lpr_minimum 或更新，当前为 $lpr_product"; return 1; }
    [ "$(lpr_profile_value "$lpr_manifest" SupportedArchitecture)" = "$lpr_arch" ] \
        || { lpr_profile_error "包内架构不匹配"; return 1; }
    [ "$(lpr_profile_value "$lpr_manifest" DockVersion)" = 2427.6 ] \
        || { lpr_profile_error "包内 Dock 版本不匹配"; return 1; }
    lpr_format="$(lpr_profile_value "$lpr_manifest" FormatVersion)"
    case "$lpr_format" in
        2)
            lpr_prefix="Variants:$lpr_build"
            lpr_supported_build="$(lpr_profile_value "$lpr_manifest" "$lpr_prefix:BuildVersion")"
            if [ -n "$lpr_supported_build" ]; then
                PROFILE_EXACT=1
            else
                # This exact build is not recorded: reuse the variant the
                # manifest nominates for the rest of the macOS 26 line.
                lpr_fallback="$(lpr_profile_value "$lpr_manifest" FallbackVariant)"
                [ -n "$lpr_fallback" ] \
                    || { lpr_profile_error "包内没有 macOS $lpr_product ($lpr_build) 对应的 Dock，也未配置回退变体"; return 1; }
                lpr_prefix="Variants:$lpr_fallback"
                lpr_supported_build="$(lpr_profile_value "$lpr_manifest" "$lpr_prefix:BuildVersion")"
                lpr_supported_product="$(lpr_profile_value "$lpr_manifest" "$lpr_prefix:ProductVersion")"
                [ -n "$lpr_supported_build" ] \
                    || { lpr_profile_error "回退变体 $lpr_fallback 不存在或缺少 build"; return 1; }
                PROFILE_EXACT=0
            fi
            PROFILE_VARIANT_BUILD="$lpr_supported_build"
            PROFILE_VARIANT_PRODUCT="$(lpr_profile_value "$lpr_manifest" "$lpr_prefix:ProductVersion")"
            PROFILE_CANDIDATE_SHA="$(lpr_profile_value "$lpr_manifest" "$lpr_prefix:CandidateSHA256")"
            PROFILE_EXPERIMENT="$(lpr_profile_value "$lpr_manifest" "$lpr_prefix:DockExperimentVersion")"
            PROFILE_VARIANT_DIR="$(lpr_profile_value "$lpr_manifest" "$lpr_prefix:RelativeDirectory")"
            [[ "$PROFILE_VARIANT_DIR" =~ ^variants/[0-9A-Za-z._]+$ ]] \
                || { lpr_profile_error "包内版本目录不匹配"; return 1; }
            if [ "$PROFILE_EXACT" = 1 ]; then
                PROFILE_STOCK_SHA="$(lpr_profile_value "$lpr_manifest" "$lpr_prefix:StockSourceSHA256")"
                PROFILE_STOCK_INFO_SHA="$(lpr_profile_value "$lpr_manifest" "$lpr_prefix:StockInfoPlistSHA256")"
                [ -n "$PROFILE_STOCK_SHA" ] && [ -n "$PROFILE_STOCK_INFO_SHA" ] \
                    || { lpr_profile_error "包内原版来源哈希缺失"; return 1; }
            else
                # Unknown stock bytes for this build: the caller falls back to
                # verifying Apple's signature before capturing the backup.
                PROFILE_STOCK_SHA=""
                PROFILE_STOCK_INFO_SHA=""
            fi
            ;;
        1)
            # Legacy single-build manifest: only the exact build it carries.
            lpr_supported_product="$(lpr_profile_value "$lpr_manifest" SupportedProductVersion)"
            lpr_supported_build="$(lpr_profile_value "$lpr_manifest" SupportedBuildVersion)"
            [ "$lpr_supported_product" = "$lpr_product" ] && [ "$lpr_supported_build" = "$lpr_build" ] \
                || { lpr_profile_error "此旧版清单只支持 macOS $lpr_supported_product ($lpr_supported_build)"; return 1; }
            PROFILE_EXACT=1
            PROFILE_VARIANT_PRODUCT="$lpr_supported_product"
            PROFILE_VARIANT_BUILD="$lpr_supported_build"
            PROFILE_VARIANT_DIR=.
            PROFILE_CANDIDATE_SHA="$(lpr_profile_value "$lpr_manifest" CandidateSHA256)"
            PROFILE_EXPERIMENT="$(lpr_profile_value "$lpr_manifest" DockExperimentVersion)"
            PROFILE_STOCK_SHA="$(lpr_profile_value "$lpr_manifest" StockSourceSHA256)"
            PROFILE_STOCK_INFO_SHA="$(lpr_profile_value "$lpr_manifest" StockInfoPlistSHA256)"
            ;;
        *) lpr_profile_error "不支持清单格式 $lpr_format"; return 1 ;;
    esac
    # The target's own product/build always wins: it names the backup directory
    # that uninstall restores from, and it must match the mounted system volume.
    PROFILE_PRODUCT="$lpr_product"
    PROFILE_BUILD="$lpr_build"
    PROFILE_ARCH="$lpr_arch"
    [[ "$PROFILE_CANDIDATE_SHA" =~ ^[0-9a-f]{64}$ ]] \
        || { lpr_profile_error "候选 Dock 哈希格式无效"; return 1; }
    [ "$PROFILE_EXPERIMENT" = 2427.6.9 ] \
        || { lpr_profile_error "未知的原生补丁版本"; return 1; }
    PROFILE_PACKAGE_VERSION="$(lpr_profile_value "$lpr_manifest" PackageVersion)"
    return 0
}
