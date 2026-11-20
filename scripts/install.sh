#!/bin/bash
set -o pipefail

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

# check os
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -Eqi "alpine"; then
    release="alpine"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "arch"; then
    release="arch"
else
    echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}\n" && exit 1
fi

########################
# 参数解析
########################
VERSION_ARG=""
API_HOST_ARG=""
SERVER_ID_ARG=""
SECRET_KEY_ARG=""
PACKAGE_ARG=""
CHECKSUMS_ARG=""
MANAGE_SCRIPT_ARG=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --api-host)
                API_HOST_ARG="$2"; shift 2 ;;
            --server-id)
                SERVER_ID_ARG="$2"; shift 2 ;;
            --secret-key)
                SECRET_KEY_ARG="$2"; shift 2 ;;
            --package)
                PACKAGE_ARG="$2"; shift 2 ;;
            --checksums)
                CHECKSUMS_ARG="$2"; shift 2 ;;
            --manage-script)
                MANAGE_SCRIPT_ARG="$2"; shift 2 ;;
            -h|--help)
                echo "用法: $0 [版本号] [--api-host URL] [--server-id ID] [--secret-key KEY]"
                echo "      [--package npnode-linux-<arch>.zip|.tar.gz [--checksums checksums.txt]] [--manage-script npnode.sh]"
                echo "  --package       用本地安装包安装（机器连不上 GitHub 时使用；tar.gz 不需要 unzip）"
                echo "  传了 --api-host / --server-id / --secret-key 时会重新生成配置（旧配置备份为 config.yml.bak）"
                echo "  退出码 20 表示下载不了安装包（面板远程安装据此改为直传）"
                exit 0 ;;
            --*)
                echo "未知参数: $1"; exit 1 ;;
            *)
                # 兼容第一个位置参数作为版本号
                if [[ -z "$VERSION_ARG" ]]; then
                    VERSION_ARG="$1"; shift
                else
                    shift
                fi ;;
        esac
    done
}

arch=$(uname -m)

if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64-v8a"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
else
    arch="64"
    echo -e "${red}检测架构失败，使用默认架构: ${arch}${plain}"
fi

if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ] ; then
    echo "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)，如果检测有误，请联系作者"
    exit 2
fi

# os version
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version} -le 6 ]]; then
        echo -e "${red}请使用 CentOS 7 或更高版本的系统！${plain}\n" && exit 1
    fi
    if [[ ${os_version} -eq 7 ]]; then
        echo -e "${red}注意： CentOS 7 无法使用hysteria1/2协议！${plain}\n"
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version} -lt 16 ]]; then
        echo -e "${red}请使用 Ubuntu 16 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ ${os_version} -lt 8 ]]; then
        echo -e "${red}请使用 Debian 8 或更高版本的系统！${plain}\n" && exit 1
    fi
fi

# 软件源不可用时不要卡太久（装不上的依赖后面有兜底：没有 pv 不显示进度，没有 curl 用 wget）
pm_timeout=""
command -v timeout >/dev/null 2>&1 && pm_timeout="timeout 300"

install_base() {
    need_install_apt() {
        local packages=("$@")
        local missing=()

        # 批量检查已安装的包
        local installed_list=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | sort)

        for p in "${packages[@]}"; do
            if ! echo "$installed_list" | grep -q "^${p}$"; then
                missing+=("$p")
            fi
        done

        if [[ ${#missing[@]} -gt 0 ]]; then
            echo "安装缺失的包: ${missing[*]}"
            $pm_timeout apt-get update -y >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive $pm_timeout apt-get install -y "${missing[@]}" >/dev/null 2>&1
        fi
    }

    need_install_yum() {
        local packages=("$@")
        local missing=()

        # 批量检查已安装的包
        local installed_list=$(rpm -qa --qf '%{NAME}\n' 2>/dev/null | sort)

        for p in "${packages[@]}"; do
            if ! echo "$installed_list" | grep -q "^${p}$"; then
                missing+=("$p")
            fi
        done

        if [[ ${#missing[@]} -gt 0 ]]; then
            echo "安装缺失的包: ${missing[*]}"
            $pm_timeout yum install -y "${missing[@]}" >/dev/null 2>&1
        fi
    }

    need_install_apk() {
        local packages=("$@")
        local missing=()

        # 批量检查已安装的包
        local installed_list=$(apk info 2>/dev/null | sort)

        for p in "${packages[@]}"; do
            if ! echo "$installed_list" | grep -q "^${p}$"; then
                missing+=("$p")
            fi
        done

        if [[ ${#missing[@]} -gt 0 ]]; then
            echo "安装缺失的包: ${missing[*]}"
            $pm_timeout apk add --no-cache "${missing[@]}" >/dev/null 2>&1
        fi
    }

    # 一次性安装所有必需的包
    if [[ x"${release}" == x"centos" ]]; then
        # 检查并安装 epel-release
        if ! rpm -q epel-release >/dev/null 2>&1; then
            echo "安装 EPEL 源..."
            $pm_timeout yum install -y epel-release >/dev/null 2>&1
        fi
        need_install_yum wget curl unzip tar cronie socat ca-certificates pv
        update-ca-trust force-enable >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"alpine" ]]; then
        need_install_apk wget curl unzip tar socat ca-certificates pv
        update-ca-certificates >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"debian" ]]; then
        need_install_apt wget curl unzip tar cron socat ca-certificates pv
        update-ca-certificates >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"ubuntu" ]]; then
        need_install_apt wget curl unzip tar cron socat ca-certificates pv
        update-ca-certificates >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"arch" ]]; then
        echo "更新包数据库..."
        $pm_timeout pacman -Sy --noconfirm >/dev/null 2>&1
        # --needed 会跳过已安装的包，非常高效
        echo "安装必需的包..."
        $pm_timeout pacman -S --noconfirm --needed wget curl unzip tar cronie socat ca-certificates pv >/dev/null 2>&1
    fi
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ ! -f /usr/local/NPanel-node/npnode ]]; then
        return 2
    fi
    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(service NPanel-node status | awk '{print $3}')
        if [[ x"${temp}" == x"started" ]]; then
            return 0
        else
            return 1
        fi
    else
        temp=$(systemctl status NPanel-node | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ x"${temp}" == x"running" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

generate_npnode_config() {
        local api_host="$1"
        local server_id="$2"
        local secret_key="$3"

        mkdir -p /etc/NPanel-node >/dev/null 2>&1
        cat > /etc/NPanel-node/config.yml <<EOF
Log:
  # 日志等级，可选: debug, info, warn(warning), error
  Level: warn
  # 日志输出位置，可以是文件路径，留空时使用 "stdout"（标准输出）
  Output:
  # 访问日志路径，例如logs/access.log，写none时关闭访问日志
  Access: none

Api:
  # 后端 API 地址，例如 "https://api.example.com"
  ApiHost: ${api_host}
  # 服务器唯一标识
  ServerID: ${server_id}
  # 通讯密钥，用于验证请求合法性
  SecretKey: ${secret_key}
  # 请求超时时间（单位：秒）
  Timeout: 30

Grpc:
  # 默认开启 gRPC（推送用户 / 配置变更、上报流量），地址留空时从 ApiHost 推出；面板没开放时自动改用 HTTP
  Enable: true
  Addr:
EOF
        echo -e "${green}NPanel-node 配置文件生成完成,正在重新启动服务${plain}"
        if [[ x"${release}" == x"alpine" ]]; then
            service NPanel-node restart
        else
            systemctl restart NPanel-node
        fi
        sleep 2
        check_status
        echo -e ""
        if [[ $? == 0 ]]; then
            echo -e "${green}NPanel-node 重启成功${plain}"
        else
            echo -e "${red}NPanel-node 可能启动失败，请使用 npnode log 查看日志信息${plain}"
        fi
}

# 下载不了安装包：以退出码 20 退出（面板远程安装据此改为直传安装包）
download_failed() {
    echo -e "${red}$*${plain}"
    echo -e "${yellow}机器连不上 GitHub 时，可以在别处下载 npnode-linux-${arch}.zip 传上来，用 --package 安装${plain}"
    exit 20
}

# fetch URL 输出文件：优先 curl（有 pv 时显示进度），没有 curl 用 wget
fetch() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        if command -v pv >/dev/null 2>&1 && [[ -t 2 ]]; then
            curl -fL --retry 3 --connect-timeout 10 "$url" | pv -s 30M -W -N "下载进度" > "$out"
        else
            curl -fsSL --retry 3 --connect-timeout 10 -o "$out" "$url"
        fi
    elif command -v wget >/dev/null 2>&1; then
        wget -q --tries=3 --timeout=30 -O "$out" "$url"
    else
        return 1
    fi
}

# zip_test / zip_extract：.tar.gz 用 tar；zip 优先 unzip，没有就用 python3 自带的 zipfile
# （面板直传时会把 zip 转成 tar.gz，目标机不需要 unzip）
zip_test() {
    if [[ "$1" == *.tar.gz ]]; then
        tar -tzf "$1" >/dev/null 2>&1
    elif command -v unzip >/dev/null 2>&1; then
        unzip -tq "$1" >/dev/null 2>&1
    elif command -v python3 >/dev/null 2>&1; then
        python3 -m zipfile -t "$1" >/dev/null 2>&1
    else
        echo -e "${red}缺少 unzip（自动安装失败），也没有 python3，无法解压安装包${plain}"
        exit 1
    fi
}
zip_extract() {
    if [[ "$1" == *.tar.gz ]]; then
        tar -xzf "$1" -C "$2"
    elif command -v unzip >/dev/null 2>&1; then
        unzip -o "$1" -d "$2"
    else
        python3 -m zipfile -e "$1" "$2"
    fi
}

install_npnode() {
    local version_param="$1"
    local work
    work=$(mktemp -d)
    # 任何退出（包括下载失败退出码 20）都清掉临时目录
    trap 'rm -rf "$work"' EXIT
    local zip="$work/npnode-linux-${arch}.zip"

    # 先把安装包准备好并校验，再替换现有安装：下载失败不会把正在运行的节点删掉
    if [[ -n "$PACKAGE_ARG" ]]; then
        [[ -f "$PACKAGE_ARG" ]] || { echo -e "${red}安装包不存在：${PACKAGE_ARG}${plain}"; exit 1; }
        echo -e "${green}使用本地安装包 ${PACKAGE_ARG}${plain}"
        if [[ "$PACKAGE_ARG" == *.tar.gz || "$PACKAGE_ARG" == *.tgz ]]; then
            zip="$work/npnode-linux-${arch}.tar.gz"
        fi
        cp "$PACKAGE_ARG" "$zip"
        last_version="(本地安装包)"
        if [[ -n "$CHECKSUMS_ARG" ]]; then
            [[ -f "$CHECKSUMS_ARG" ]] || { echo -e "${red}校验文件不存在：${CHECKSUMS_ARG}${plain}"; exit 1; }
            cp "$CHECKSUMS_ARG" "$work/checksums.txt"
            if ! (cd "$work" && grep " $(basename "$zip")\$" checksums.txt | sha256sum -c - >/dev/null 2>&1); then
                echo -e "${red}安装包校验失败（本机架构需要 $(basename "$zip")）${plain}"
                exit 1
            fi
        fi
    else
        if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
            download_failed "没有 curl 也没有 wget（软件源不可用？），无法下载 NPanel-node"
        fi
        if [[ -z "$version_param" ]]; then
            last_version=""
            if fetch "https://api.github.com/repos/yunsen1599/Bearnode/releases/latest" "$work/latest.json"; then
                last_version=$(grep '"tag_name":' "$work/latest.json" | sed -E 's/.*"([^"]+)".*/\1/')
            fi
            if [[ -z "$last_version" ]]; then
                download_failed "检测 NPanel-node 版本失败：连不上 GitHub，或超出 Github API 限制（可稍后再试，或手动指定版本）"
            fi
            echo -e "${green}检测到最新版本：${last_version}，开始安装...${plain}"
        else
            last_version=$version_param
        fi
        url="https://github.com/yunsen1599/Bearnode/releases/download/${last_version}/npnode-linux-${arch}.zip"
        if ! fetch "$url" "$zip"; then
            download_failed "下载 NPanel-node ${last_version} 失败，请确保此版本存在、服务器能够下载 Github 的文件"
        fi
    fi

    if ! zip_test "$zip"; then
        echo -e "${red}NPanel-node 安装包无效，请检查版本或稍后重试${plain}"
        exit 1
    fi
    if [[ -e /usr/local/NPanel-node/ ]]; then
        rm -rf /usr/local/NPanel-node/
    fi
    mkdir /usr/local/NPanel-node/ -p
    cd /usr/local/NPanel-node/
    zip_extract "$zip" /usr/local/NPanel-node/
    rm -rf "$work"
    for required_file in npnode geoip.dat geosite.dat config.yml; do
        if [[ ! -f "$required_file" ]]; then
            echo -e "${red}安装包缺少 ${required_file}，请检查 Release 资产是否完整${plain}"
            exit 1
        fi
    done
    chmod +x npnode
    mkdir /etc/NPanel-node/ -p
    cp geoip.dat /etc/NPanel-node/
    cp geosite.dat /etc/NPanel-node/
    if [[ x"${release}" == x"alpine" ]]; then
        rm /etc/init.d/NPanel-node -f
        cat <<EOF > /etc/init.d/NPanel-node
#!/sbin/openrc-run

name="NPanel-node"
description="NPanel-node"

command="/usr/local/NPanel-node/npnode"
command_args="server"
command_user="root"

pidfile="/run/npnode.pid"
command_background="yes"

depend() {
        need net
}
EOF
        chmod +x /etc/init.d/NPanel-node
        rc-update add NPanel-node default
        echo -e "${green}NPanel-node ${last_version}${plain} 安装完成，已设置开机自启"
    else
        rm /etc/systemd/system/NPanel-node.service -f
        cat <<EOF > /etc/systemd/system/NPanel-node.service
[Unit]
Description=NPanel-node Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
Group=root
Type=simple
LimitAS=infinity
LimitRSS=infinity
LimitCORE=infinity
LimitNOFILE=999999
WorkingDirectory=/usr/local/NPanel-node/
ExecStart=/usr/local/NPanel-node/npnode server
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl stop NPanel-node
        systemctl enable NPanel-node
        echo -e "${green}NPanel-node ${last_version}${plain} 安装完成，已设置开机自启"
    fi

    if [[ -n "$API_HOST_ARG" && -n "$SERVER_ID_ARG" && -n "$SECRET_KEY_ARG" ]]; then
        # 通过参数传入了完整对接信息（面板一键 / 远程安装）：按参数生成配置，旧配置备份
        if [[ -f /etc/NPanel-node/config.yml ]]; then
            cp /etc/NPanel-node/config.yml /etc/NPanel-node/config.yml.bak
            echo -e "${yellow}已有配置备份为 /etc/NPanel-node/config.yml.bak${plain}"
        fi
        generate_npnode_config "$API_HOST_ARG" "$SERVER_ID_ARG" "$SECRET_KEY_ARG"
        echo -e "${green}已根据参数生成 /etc/NPanel-node/config.yml${plain}"
        first_install=false
    elif [[ ! -f /etc/NPanel-node/config.yml ]]; then
        cp config.yml /etc/NPanel-node/
        first_install=true
    else
        if [[ x"${release}" == x"alpine" ]]; then
            service NPanel-node start
        else
            systemctl start NPanel-node
        fi
        sleep 2
        check_status
        echo -e ""
        if [[ $? == 0 ]]; then
            echo -e "${green}NPanel-node 重启成功${plain}"
        else
            echo -e "${red}NPanel-node 可能启动失败，请使用 npnode log 查看日志信息${plain}"
        fi
        first_install=false
    fi


    if [[ -n "$MANAGE_SCRIPT_ARG" && -f "$MANAGE_SCRIPT_ARG" ]]; then
        cp "$MANAGE_SCRIPT_ARG" /usr/bin/npnode
        chmod +x /usr/bin/npnode
    elif fetch https://raw.githubusercontent.com/yunsen1599/Bearnode/main/scripts/npnode.sh /usr/bin/npnode.new; then
        mv /usr/bin/npnode.new /usr/bin/npnode
        chmod +x /usr/bin/npnode
    else
        rm -f /usr/bin/npnode.new
        echo -e "${yellow}管理脚本 npnode 下载失败（不影响节点运行），之后可执行 npnode update 重新获取${plain}"
    fi

    cd $cur_dir
    rm -f install.sh
    echo "------------------------------------------"
    echo "NPanel-node 管理脚本使用方法: "
    echo "------------------------------------------"
    echo "npnode              - 显示管理菜单 (功能更多)"
    echo "npnode start        - 启动 NPanel-node"
    echo "npnode stop         - 停止 NPanel-node"
    echo "npnode restart      - 重启 NPanel-node"
    echo "npnode status       - 查看 NPanel-node 状态"
    echo "npnode enable       - 设置 NPanel-node 开机自启"
    echo "npnode disable      - 取消 NPanel-node 开机自启"
    echo "npnode log          - 查看 NPanel-node 日志"
    echo "npnode generate     - 生成 NPanel-node 配置文件"
    echo "npnode update       - 更新 NPanel-node"
    echo "npnode update x.x.x - 安装 NPanel-node 指定版本"
    echo "npnode install      - 安装 NPanel-node"
    echo "npnode uninstall    - 卸载 NPanel-node"
    echo "npnode version      - 查看 NPanel-node 版本"
    echo "------------------------------------------"

    if [[ $first_install == true ]]; then
        read -rp "检测到你为第一次安装 NPanel-node，是否自动生成 /etc/NPanel-node/config.yml？(y/n): " if_generate
        if [[ "$if_generate" =~ ^[Yy]$ ]]; then
            # 交互式收集参数，提供示例默认值
            read -rp "面板API地址[格式: https://example.com/]: " api_host
            api_host=${api_host:-https://example.com/}
            read -rp "服务器ID: " server_id
            server_id=${server_id:-1}
            read -rp "通讯密钥: " secret_key

            # 生成配置文件（覆盖可能从包中复制的模板）
            generate_npnode_config "$api_host" "$server_id" "$secret_key"
        else
            echo "${green}已跳过自动生成配置。如需后续生成，可执行: npnode generate${plain}"
        fi
    fi
}

parse_args "$@"
echo -e "${green}开始安装${plain}"
install_base
install_npnode "$VERSION_ARG"
