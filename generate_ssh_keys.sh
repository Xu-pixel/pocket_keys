#!/bin/bash

# 脚本：扫描 ~/.ssh/config，让用户选择设备并生成椭圆曲线密钥

SSH_CONFIG="$HOME/.ssh/config"
TEMP_FILE=$(mktemp)

# 检查配置文件是否存在
if [ ! -f "$SSH_CONFIG" ]; then
    echo "错误: $SSH_CONFIG 不存在"
    exit 1
fi

# 解析 SSH config 文件，提取 Host 块
declare -a HOSTS
declare -a HOST_NAMES
declare -a IDENTITY_FILES
declare -a HOST_NAMES_FULL
declare -a USER_NAMES
declare -a PORTS

parse_ssh_config() {
    local current_host=""
    local current_identity=""
    local current_hostname=""
    local current_user=""
    local current_port=""
    local in_host_block=false
    
    while IFS= read -r line || [ -n "$line" ]; do
        # 跳过注释和空行
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line// }" ]]; then
            continue
        fi
        
        # 检测 Host 块开始
        if [[ "$line" =~ ^[Hh]ost[[:space:]]+(.+)$ ]]; then
            # 保存之前的 Host（如果有）
            if [ "$in_host_block" = true ] && [ -n "$current_host" ]; then
                HOST_NAMES+=("$current_host")
                HOST_NAMES_FULL+=("${current_hostname:-$current_host}")
                IDENTITY_FILES+=("$current_identity")
                USER_NAMES+=("$current_user")
                PORTS+=("$current_port")
            fi
            
            # 开始新的 Host 块
            current_host="${BASH_REMATCH[1]}"
            current_identity=""
            current_hostname=""
            current_user=""
            current_port=""
            in_host_block=true
        elif [ "$in_host_block" = true ]; then
            # 在 Host 块内查找各种配置
            if [[ "$line" =~ ^[[:space:]]*[Ii]dentity[Ff]ile[[:space:]]+(.+)$ ]]; then
                current_identity="${BASH_REMATCH[1]}"
                # 展开 ~ 符号
                current_identity="${current_identity/#\~/$HOME}"
            elif [[ "$line" =~ ^[[:space:]]*[Hh]ost[Nn]ame[[:space:]]+(.+)$ ]]; then
                current_hostname="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^[[:space:]]*[Uu]ser[[:space:]]+(.+)$ ]]; then
                current_user="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^[[:space:]]*[Pp]ort[[:space:]]+([0-9]+)$ ]]; then
                current_port="${BASH_REMATCH[1]}"
            fi
        fi
    done < "$SSH_CONFIG"
    
    # 保存最后一个 Host
    if [ "$in_host_block" = true ] && [ -n "$current_host" ]; then
        HOST_NAMES+=("$current_host")
        HOST_NAMES_FULL+=("${current_hostname:-$current_host}")
        IDENTITY_FILES+=("$current_identity")
        USER_NAMES+=("$current_user")
        PORTS+=("$current_port")
    fi
}

# 上传公钥到服务器
upload_public_key() {
    local host_name="$1"
    local hostname="$2"
    local user="$3"
    local port="$4"
    local identity_file="$5"
    local public_key_file="${identity_file}.pub"
    
    if [ ! -f "$public_key_file" ]; then
        echo "错误: 公钥文件不存在: $public_key_file"
        return 1
    fi
    
    # 读取公钥内容（转义单引号）
    local public_key_content
    public_key_content=$(cat "$public_key_file" | sed "s/'/'\\\\''/g")
    
    echo ""
    echo "正在将公钥上传到服务器: $host_name ($hostname)"
    
    # 方法1: 尝试使用 ssh-copy-id（如果可用）
    # ssh-copy-id 会使用 SSH config 中的配置，包括旧的 IdentityFile（如果存在）
    if command -v ssh-copy-id &> /dev/null; then
        echo "尝试使用 ssh-copy-id..."
        # 使用 Host 名称连接，SSH 会自动读取 config 中的配置（包括旧的密钥）
        # 这样可以用旧密钥认证，然后添加新公钥
        if ssh-copy-id -i "$public_key_file" -f "$host_name" 2>&1; then
            echo "✓ 公钥上传成功（使用 ssh-copy-id）"
            return 0
        fi
        echo "ssh-copy-id 失败，尝试其他方法..."
    fi
    
    # 方法2: 手动上传
    # 先尝试使用 SSH config 中的配置（可能包含旧密钥）连接
    echo "尝试手动上传公钥..."
    echo "提示: 如果服务器需要密码认证，请输入密码"
    
    local ssh_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
    
    # 创建远程目录（如果不存在）并追加公钥
    # 检查公钥是否已存在，避免重复添加
    local remote_command="
        mkdir -p ~/.ssh && 
        chmod 700 ~/.ssh && 
        if ! grep -Fxq '$public_key_content' ~/.ssh/authorized_keys 2>/dev/null; then
            echo '$public_key_content' >> ~/.ssh/authorized_keys && 
            chmod 600 ~/.ssh/authorized_keys && 
            echo '公钥已添加到 authorized_keys'
        else
            echo '公钥已存在于 authorized_keys 中，跳过'
        fi
    "
    
    # 使用 Host 名称连接，SSH 会自动使用 config 中的配置
    # 如果 config 中有旧的 IdentityFile，会使用它进行认证
    if ssh $ssh_opts "$host_name" "$remote_command" 2>&1; then
        echo "✓ 公钥上传成功（手动方式）"
        return 0
    else
        echo ""
        echo "✗ 自动上传失败"
        echo ""
        echo "可能的原因:"
        echo "  1. 服务器需要密码认证（请手动输入密码重试）"
        echo "  2. 服务器未配置 SSH 访问"
        echo "  3. 网络连接问题"
        echo ""
        echo "请手动将以下公钥添加到服务器的 ~/.ssh/authorized_keys:"
        echo "----------------------------------------"
        cat "$public_key_file"
        echo "----------------------------------------"
        echo ""
        echo "或者使用以下命令手动上传（可能需要输入密码）:"
        echo "  ssh-copy-id -i $public_key_file $host_name"
        echo ""
        echo "或者手动执行:"
        echo "  cat $public_key_file | ssh $host_name 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'"
        return 1
    fi
}

# 解析配置文件
parse_ssh_config

# 检查是否找到任何 Host
if [ ${#HOST_NAMES[@]} -eq 0 ]; then
    echo "错误: 在 $SSH_CONFIG 中未找到任何 Host 配置"
    exit 1
fi

# 显示可用的 Host 列表
echo "=========================================="
echo "SSH Config 中的设备列表:"
echo "=========================================="
for i in "${!HOST_NAMES[@]}"; do
    idx=$((i + 1))
    host="${HOST_NAMES[$i]}"
    hostname="${HOST_NAMES_FULL[$i]}"
    user="${USER_NAMES[$i]}"
    port="${PORTS[$i]}"
    identity="${IDENTITY_FILES[$i]}"
    
    # 构建连接信息
    conn_info=""
    if [ -n "$user" ]; then
        conn_info="${user}@"
    fi
    conn_info="${conn_info}${hostname}"
    if [ -n "$port" ]; then
        conn_info="${conn_info}:${port}"
    fi
    
    if [ -z "$identity" ]; then
        identity="(未设置，将自动生成)"
    fi
    
    printf "%2d. %-25s | %-35s | %s\n" "$idx" "$host" "$conn_info" "$identity"
done
echo "=========================================="

# 获取用户选择
echo ""
read -p "请选择要生成密钥的设备编号（多个用逗号分隔，如: 1,3,5）: " selection

if [ -z "$selection" ]; then
    echo "未选择任何设备，退出"
    exit 0
fi

# 处理用户选择
IFS=',' read -ra SELECTED_INDICES <<< "$selection"

for idx_str in "${SELECTED_INDICES[@]}"; do
    # 去除空格
    idx_str=$(echo "$idx_str" | tr -d ' ')
    
    # 验证是否为数字
    if ! [[ "$idx_str" =~ ^[0-9]+$ ]]; then
        echo "警告: '$idx_str' 不是有效的数字，跳过"
        continue
    fi
    
    # 转换为数组索引（从1开始转换为0开始）
    array_idx=$((idx_str - 1))
    
    # 验证索引范围
    if [ $array_idx -lt 0 ] || [ $array_idx -ge ${#HOST_NAMES[@]} ]; then
        echo "警告: 索引 $idx_str 超出范围，跳过"
        continue
    fi
    
    host_name="${HOST_NAMES[$array_idx]}"
    hostname="${HOST_NAMES_FULL[$array_idx]}"
    user="${USER_NAMES[$array_idx]}"
    port="${PORTS[$array_idx]}"
    identity_file="${IDENTITY_FILES[$array_idx]}"
    
    # 如果没有 IdentityFile，使用默认路径
    if [ -z "$identity_file" ] || [ "$identity_file" = "(未设置 IdentityFile)" ]; then
        identity_file="$HOME/.ssh/id_ed25519_${host_name}"
    fi
    
    # 确保目录存在
    key_dir=$(dirname "$identity_file")
    if [ ! -d "$key_dir" ]; then
        mkdir -p "$key_dir"
        echo "创建目录: $key_dir"
    fi
    
    # 检查密钥是否已存在
    if [ -f "$identity_file" ]; then
        echo ""
        read -p "密钥文件 $identity_file 已存在，是否覆盖？(y/N): " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            echo "跳过 $host_name"
            continue
        fi
    fi
    
    # 生成椭圆曲线密钥（使用 ed25519）
    echo ""
    echo "正在为 $host_name 生成椭圆曲线密钥..."
    echo "私钥路径: $identity_file"
    
    # 生成密钥（不设置密码短语，使用 -N ""）
    if ssh-keygen -t ed25519 -f "$identity_file" -N "" -C "generated_for_${host_name}"; then
        # 设置权限
        chmod 600 "$identity_file"
        chmod 644 "${identity_file}.pub"
        
        echo "✓ 密钥生成成功！"
        echo "  私钥: $identity_file (权限: 600)"
        echo "  公钥: ${identity_file}.pub (权限: 644)"
        
        # 询问是否上传公钥到服务器
        if [ -n "$hostname" ]; then
            echo ""
            read -p "是否将公钥上传到服务器 $host_name ($hostname)？(Y/n): " upload_choice
            if [[ ! "$upload_choice" =~ ^[Nn]$ ]]; then
                upload_public_key "$host_name" "$hostname" "$user" "$port" "$identity_file"
            else
                echo "跳过上传，公钥内容如下（可手动复制）:"
                echo "----------------------------------------"
                cat "${identity_file}.pub"
                echo "----------------------------------------"
            fi
        else
            echo ""
            echo "注意: 未找到 HostName 配置，无法自动上传公钥"
            echo "公钥内容如下（请手动复制到服务器）:"
            echo "----------------------------------------"
            cat "${identity_file}.pub"
            echo "----------------------------------------"
        fi
    else
        echo "✗ 密钥生成失败: $host_name"
    fi
done

# 清理临时文件
rm -f "$TEMP_FILE"

echo ""
echo "完成！"
