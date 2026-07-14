#!/usr/bin/env bash

update_feeds() {
    local FEEDS_PATH="$BUILD_DIR/$FEEDS_CONF"
    if [[ -f "$BUILD_DIR/feeds.conf" ]]; then
        FEEDS_PATH="$BUILD_DIR/feeds.conf"
    fi

    sed -i '/^src-link/d' "$FEEDS_PATH"

    if ! grep -q "openwrt-packages" "$FEEDS_PATH"; then
        [ -z "$(tail -c 1 "$FEEDS_PATH")" ] || echo "" >>"$FEEDS_PATH"
        echo "src-git openwrt_packages https://github.com/kenzok8/openwrt-packages.git" >>"$FEEDS_PATH"
    fi

    if ! grep -q "openclash" "$FEEDS_PATH"; then
        [ -z "$(tail -c 1 "$FEEDS_PATH")" ] || echo "" >>"$FEEDS_PATH"
        echo "src-git openclash https://github.com/vernesong/OpenClash.git" >>"$FEEDS_PATH"
    fi

    if [ ! -f "$BUILD_DIR/include/bpf.mk" ]; then
        touch "$BUILD_DIR/include/bpf.mk"
    fi

    echo "=== 开始执行 feeds update ==="

    # 检查 feeds 是否已存在（检测 packages 这个必备 feed）
    if [[ -d "$BUILD_DIR/feeds/packages/.git" ]]; then
        # feeds 已存在，只做增量更新（git pull），避免重新克隆
        echo "Feeds 目录已存在，执行增量更新..."
    else
        # 首次克隆，先清理再完整更新
        echo "Feeds 目录不存在，执行首次克隆..."
        (cd "$BUILD_DIR" && ./scripts/feeds clean) || true
    fi

    # 带重试地执行 feeds update
    # 说明：openclash 等大仓库在克隆时偶发网络超时，导致 ./scripts/feeds update -a
    # 整体返回非 0。此处增加重试，避免一次性网络抖动直接中断整个构建。
    local max_retry=3 retry=0
    while [[ $retry -lt $max_retry ]]; do
        if (cd "$BUILD_DIR" && ./scripts/feeds update -a); then
            break
        fi
        retry=$((retry + 1))
        warn "feeds update 失败（第 ${retry} 次），5 秒后重试..."
        sleep 5
    done

    if [[ $retry -ge $max_retry ]]; then
        error "feeds update 重试 ${max_retry} 次仍失败，请检查网络后重试"
        exit 1
    fi
    
    echo "=== feeds update 完成 ==="
}

install_feeds() {
    cd "$BUILD_DIR" || exit 1
    
    echo "=== 开始安装 feeds 包 ==="
    
    # 先更新 feeds 索引
    echo "更新 feeds 索引..."
    ./scripts/feeds update -i
    
    # 先安装 openwrt-packages 中的包
    echo "安装 openwrt-packages 包..."
    install_openwrt_packages
    
    # 安装其他 feeds 的包
    for dir in "$BUILD_DIR"/feeds/*; do
        if [ -d "$dir" ] && [[ ! "$dir" == *.tmp ]] && [[ ! "$dir" == *.index ]] && [[ ! "$dir" == *.targetindex ]]; then
            local feed_name=$(basename "$dir")
            if [[ "$feed_name" != "openwrt_packages" ]]; then
                ./scripts/feeds install -f -ap "$feed_name"
            fi
        fi
    done
    
    echo "=== feeds 包安装完成 ==="
    cd - >/dev/null || exit 1
}