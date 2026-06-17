#!/bin/bash
export LANG=en_US.UTF-8

red(){ echo -e "\033[31m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}
blue(){ echo -e "\033[36m\033[01m$1\033[0m";}
white(){ echo -e "\033[37m\033[01m$1\033[0m";}
readp(){ read -p "$(yellow "$1")" $2;}

# root权限检查
[[ $EUID -ne 0 ]] && yellow "请以root模式运行脚本" && exit 1

# 允许使用 Ctrl+C 打断退出
trap 'echo -e "\n${red}脚本已被用户手动中断退出。${plain}"; exit 1' INT

WORK_DIR="/root/xsjca"
ACME_BIN="/root/.acme.sh/acme.sh"

# 自动检测并安装所需 system 底层依赖
install_deps(){
    if [ ! -f /root/.xsjca_deps_done ]; then
        green "开始检测并前台安装所需系统底层依赖组件..."
        if [ -x "$(command -v apt-get)" ]; then
            apt update -y && apt install socat cron curl openssl lsof dnsutils tar wget jq -y
        elif [ -x "$(command -v yum)" ]; then
            yum install epel-release -y
            yum install socat cronie lsof bind-utils tar wget openssl curl jq -y
        elif [ -x "$(command -v dnf)" ]; then
            dnf install socat cronie lsof bind-utils tar wget openssl curl jq -y
        fi
        touch /root/.xsjca_deps_done
        green "系统依赖组件补齐完成！"
    fi
}

# 释放 80 端口
stop_80_port(){
    if [[ -n $(lsof -i :80|grep -v "PID") ]]; then
        yellow "检测到 80 端口被占用，正在前台执行强制释放..."
        lsof -i :80|grep -v "PID"|awk '{print "kill -9",$2}'|sh
        green "80 端口释放完毕。"
        sleep 1
    fi
}

# 初始化安装 acme.sh 核心
init_acme_core(){
    if [ ! -f "$ACME_BIN" ]; then
        green "开始安装acme.sh申请证书脚本"
        curl https://get.acme.sh | sh -s email="$1"
        green "安装acme.sh证书申请程序成功"
        $ACME_BIN --upgrade --auto-upgrade
    fi
}

# 统一提取、复制并打印证书路径的逻辑
archive_and_display_output(){
    local name=$1
    local target_path="${WORK_DIR}/${name}"
    
    mkdir -p "$target_path"
    $ACME_BIN --install-cert -d "$name" --ecc \
        --key-file "${target_path}/private.key" \
        --fullchain-file "${target_path}/cert.crt"
        
    if [[ -s "${target_path}/cert.crt" && -s "${target_path}/private.key" ]]; then
        chmod 600 "${target_path}/private.key"
        chmod 644 "${target_path}/cert.crt"
        
        # 写入定时续期任务
        crontab -l 2>/dev/null | grep -v 'acme.sh --cron' > /tmp/cron.tmp
        echo "0 0 * * * bash /root/.acme.sh/acme.sh --cron -f >/dev/null 2>&1" >> /tmp/cron.tmp
        crontab /tmp/cron.tmp && rm -f /tmp/cron.tmp
        
        # 极简纯路径输出，无等号边框
        echo
        green "证书申请成功！"
        yellow "域名证书（cert.crt）和密钥（private.key）已保存到 /root/xsjca文件夹内"
        green "公钥文件crt路径如下，可直接复制：/root/xsjca/${name}/cert.crt"
        green "密钥文件key路径如下，可直接复制：/root/xsjca/${name}/private.key"
        echo
    else
        red "证书同步失败，请检查上方的 acme.sh 底层输出报错。"
        rm -rf "$target_path"
        exit 1
    fi
}

# 失败排查提示函数
show_fail_tips(){
    echo
    red "遗憾，域名证书申请失败，建议如下："
    yellow "1、如果解析到的IP是104.2开头的或者172开头的IP，请确保CF中的CDN黄云已关闭，解析的IP必须是VPS的本地IP"
    echo
    yellow "2、更换下二级域名自定义名称再尝试执行重装脚本（重要）"
    green "例：原二级域名 x.example.com ，在cloudflare中重命名其中的x名称"
    echo
    yellow "3、因为同个本地IP连续多次申请证书有时间限制，等一段时间再重装脚本"
    exit 1
}

# 菜单选择逻辑控制循环
while true; do
    clear
    echo "=================================================="
    green "          KogamiAkira证书申请脚本"
    echo "=================================================="
    yellow " 1. 申请域名证书"
    yellow " 2. 申请IP证书"
    yellow " 3. 手动一键证书续期"
    yellow " 4. 删除证书并卸载一键ACME证书申请脚本"
    yellow " 0. 退出脚本"
    echo "=================================================="
    readp "请选择操作 [0-4] (默认 1): " NumberInput
    NumberInput=${NumberInput:-1}
    
    if [[ "$NumberInput" =~ ^[0-4]$ ]]; then
        break
    else
        red "输入错误！请重新输入正确的选项数字 [0-4]！"
        sleep 1.5
    fi
done

# 分支逻辑处理
case "$NumberInput" in
    1 )
        install_deps
        readp "请输入注册邮箱 (直接回车全自动生成8位随机Gmail): " INPUT_EMAIL
        if [ -z "$INPUT_EMAIL" ]; then
            Aemail="$(date +%s%N | md5sum | cut -c 1-8)@gmail.com"
            yellow "已生成随机邮箱: ${Aemail}"
        else
            Aemail="$INPUT_EMAIL"
        fi
        
        readp "请输入解析完成的域名: " DOMAIN
        [[ -z "$DOMAIN" ]] && red "域名不能为空！" && exit 1
        
        v4_local=$(curl -s4m5 icanhazip.com -k)
        domain_ip=$(dig @8.8.8.8 +time=2 +short "$DOMAIN" 2>/dev/null | grep -m1 '^[0-9]')
        
        echo
        blue "当前域名解析到的IPV4地址：${domain_ip:-'未检测到'}"
        blue "当前VPS本地真实公网IPV4地址：${v4_local:-'未检测到'}"
        echo
        
        if [[ ! -z "$v4_local" && "$domain_ip" == "$v4_local" ]]; then
            green "IP匹配正确，申请证书开始…………"
            echo
            
            init_acme_core "$Aemail"
            stop_80_port
            $ACME_BIN --set-default-ca --server letsencrypt
            $ACME_BIN --issue -d "$DOMAIN" --standalone -k ec-256 --force
            
            if [ $? -eq 0 ]; then
                archive_and_display_output "$DOMAIN"
            else
                show_fail_tips
            fi
        else
            show_fail_tips
        fi
        ;;
        
    2 )
        install_deps
        readp "请输入注册邮箱 (直接回车全自动生成8位随机Gmail): " INPUT_EMAIL
        if [ -z "$INPUT_EMAIL" ]; then
            Aemail="$(date +%s%N | md5sum | cut -c 1-8)@gmail.com"
            yellow "已生成随机邮箱: ${Aemail}"
        else
            Aemail="$INPUT_EMAIL"
        fi
        
        v4_local=$(curl -s4m5 icanhazip.com -k)
        readp "请输入当前VPS公网IP (直接回车全自动获取本机IP): " INPUT_IP
        TARGET_IP=${INPUT_IP:-$v4_local}
        
        if [[ "$TARGET_IP" != "$v4_local" ]]; then
            red "错误：输入的 IP ($TARGET_IP) 与本机实际公网 IP ($v4_local) 不符！" && exit 1
        fi
        
        init_acme_core "$Aemail"
        stop_80_port
        $ACME_BIN --register-account -m "$Aemail" --server zerossl || true
        $ACME_BIN --set-default-ca --server zerossl
        $ACME_BIN --issue -d "$TARGET_IP" --standalone -k ec-256 --force
        
        if [ $? -eq 0 ]; then
            archive_and_display_output "$TARGET_IP"
        else
            red "IP证书申请失败，请检查 80 端口或 ZeroSSL 服务器连通性。"
        fi
        ;;
        
    3 )
        if [ ! -f "$ACME_BIN" ]; then
            red "系统内未安装 acme.sh 核心，无法续期！" && exit 1
        fi
        green "正在前台强制续期系统内现存的所有证书..."
        $ACME_BIN --cron -f
        green "续期动作轮询结束。"
        ;;
        
    4 )
        # 选项 4：彻底集成证书清除与内核卸载
        red "=================================================="
        red " 警告：该操作将彻底清空 /root/xsjca 根文件夹、所有现存证书及自动续签任务！"
        red "=================================================="
        readp "确定要彻底删除证书并卸载一键申请脚本吗？(输入 y 确认 / 其他任意键取消): " DEL_CONFIRM
        if [[ "$DEL_CONFIRM" == "y" || "$DEL_CONFIRM" == "Y" ]]; then
            # 如果 acme.sh 存在，调用官方注销卸载
            if [ -f "$ACME_BIN" ]; then
                $ACME_BIN --uninstall >/dev/null 2>&1
            fi
            # 强力抹除核心母体目录、生成的 xsjca 证书文件和依赖标记，实现0残留
            rm -rf /root/.acme.sh
            rm -rf "$WORK_DIR"
            rm -f /root/.xsjca_deps_done
            
            # 清理系统层级的 crontab 计划任务记录
            crontab -l 2>/dev/null | grep -v 'acme.sh --cron' > /tmp/cron.tmp
            crontab /tmp/cron.tmp && rm -f /tmp/cron.tmp
            
            green "删除并卸载完毕！所有申请的证书和环境组件已彻底被清理干净！"
        else
            green "操作已安全取消。"
        fi
        ;;
        
    0 )
        exit 0
        ;;
esac

exit 0