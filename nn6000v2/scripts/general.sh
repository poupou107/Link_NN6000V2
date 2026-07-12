#!/usr/bin/env bash
# Module: General Preparation

# 判断配置文件中是否选中了某个包（供 passwall 等按需克隆/安装使用）
# 需在调用方设置 CONFIG_FILE 变量（指向 build.sh 使用的 .config 源文件）
config_has() {
    local pkg="$1"
    [[ -n "${CONFIG_FILE:-}" ]] && [[ -f "$CONFIG_FILE" ]] \
        && grep -q "^CONFIG_PACKAGE_${pkg}=y$" "$CONFIG_FILE"
}

clone_repo() {
    if [[ ! -d $BUILD_DIR ]]; then
        echo "克隆仓库: $REPO_URL 分支: $REPO_BRANCH"
        if ! git clone --depth 1 -b $REPO_BRANCH $REPO_URL $BUILD_DIR; then
            echo "错误：克隆仓库 $REPO_URL 失败" >&2
            exit 1
        fi
    fi
}

clean_up() {
    if [[ ! -d "$BUILD_DIR" ]]; then
        echo "Build directory $BUILD_DIR does not exist"
        return
    fi
    cd "$BUILD_DIR"
    if [[ -f ".config" ]]; then
        \rm -f ".config"
    fi
    if [[ -d "tmp" ]]; then
        \rm -rf "tmp"
    fi
    if [[ -d "logs" ]]; then
        \rm -rf "logs/*"
    fi
    mkdir -p "tmp"
    echo "1" >"tmp/.build"
}

reset_feeds_conf() {
    git reset --hard origin/$REPO_BRANCH
    git pull
    if [[ $COMMIT_HASH != "none" ]]; then
        git checkout $COMMIT_HASH
    fi
}