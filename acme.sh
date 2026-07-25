#!/bin/bash
export LANG=en_US.UTF-8

red(){ echo -e "\033[31m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}
blue(){ echo -e "\033[36m\033[01m$1\033[0m";}
white(){ echo -e "\033[37m\033[01m$1\033[0m";}
readp(){ read -p "$(yellow "$1")" $2;}

[[ $EUID -ne 0 ]] && yellow "请以root模式运行脚本" && exit 1
trap 'echo -e "\033[0m"; exit 1' INT

WORK_DIR="/root/xsjca"
ACME_BIN="/root/.acme.sh/acme.sh"

install_deps(){
    if [ ! -f /root/.xsjca_deps_done ]; then
        green "检测所需依赖..."
        if [ -x "$(command -v apt-get)" ]; then
            apt update -y && apt install socat cron curl openssl lsof dnsutils tar wget jq -y
        elif [ -x "$(command -v yum)" ]; then
            yum install epel-release -y
            yum install socat cronie lsof bind-utils tar wget openssl curl jq -y
        elif [ -x "$(command -v dnf)" ]; then
            dnf install socat cronie lsof bind-utils tar wget openssl curl jq -y
        fi
        touch /root/.xsjca_deps_done
        green "依赖安装完成！"
    fi
    
    if [[ -z $(curl -s4m5 icanhazip.com -k) ]]; then
        yellow "检测到当前 VPS 为纯 IPV6 环境，正在全自动补充 DNS64 解析..."
        echo -e "nameserver 2a00:1098:2b::1\nnameserver 2a00:1098:2b::2\nnameserver 2a01:4f8:c2c:123f::1" > /etc/resolv.conf
        sleep 1
    fi
}

stop_80_port(){
    if [[ -n $(lsof -i :80|grep -v "PID") ]]; then
        yellow "检测到 80 端口被占用，正在前台执行强制释放..."
        lsof -i :80|grep -v "PID"|awk '{print "kill -9",$2}'|sh
        green " 80 端口释放完毕。"
        sleep 1
    fi
}

init_acme_core(){
    green "开始安装 acme.sh 申请证书脚本"
    curl https://get.acme.sh | sh -s email="$1"
    green "安装 acme.sh 证书申请程序成功"
    $ACME_BIN --upgrade --auto-upgrade
}

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
        
        crontab -l 2>/dev/null | grep -v 'acme.sh --cron' > /tmp/cron.tmp
        echo "0 0 * * * bash /root/.acme.sh/acme.sh --cron -f >/dev/null 2>&1" >> /tmp/cron.tmp
        crontab /tmp/cron.tmp && rm -f /tmp/cron.tmp
        
        local cert_type="域名证书"
        [[ "$NumberInput" == "2" ]] && cert_type="IP证书"
        
        echo
        green "${cert_type}申请成功或已存在！${cert_type}（cert.crt）和密钥（private.key）已保存到 ${target_path} 文件夹内"
        green "公钥文件crt路径如下，可直接复制 "
        yellow "${target_path}/cert.crt"
        green "密钥文件key路径如下，可直接复制"
        yellow "${target_path}/private.key"
        echo
    else
        red "证书同步失败，请检查上方的 acme.sh 底层输出报错。"
        rm -rf "$target_path"
        exit 1
    fi
}

get_local_ips(){
    v4_local=$(curl -s4m5 icanhazip.com -k)
    v6_local=$(curl -s6m5 icanhazip.com -k)
    if [[ -n $v4_local && -n $v6_local ]]; then
        vpsip="$v4_local 和 $v6_local"
    else
        vpsip="${v4_local:-$v6_local}"
    fi
}

show_cert_list(){
    if [ ! -f "$ACME_BIN" ]; then
        red "未安装 acme.sh，无法查询！" && return
    fi
    green "Main_Domain 下显示的域名就是已申请成功的域名证书，Renew 下显示对应域名证书的自动续期时间点"
    $ACME_BIN --list
    echo
}

# ==================== 主菜单 ====================
while true; do
    clear
    echo "=================================================="
    green "          KogamiAkira证书申请脚本"
    echo "=================================================="
    yellow " 1. 申请域名证书(需域名)"
    yellow " 2. 申请IP证书(无需域名)"
    yellow " 3. DNS API模式申请证书（需域名、ID、Key）"
    yellow " 4. 查询已申请成功的域名及自动续期时间点"
    yellow " 5. 手动一键证书续期"
    yellow " 6. 删除证书并卸载一键ACME证书申请脚本"
    yellow " 0. 退出脚本"
    echo "=================================================="
    readp "请选择操作 [0-6] (默认 1): " NumberInput
    NumberInput=${NumberInput:-1}
    if [[ "$NumberInput" =~ ^[0-6]$ ]]; then break; fi
    red "输入错误！请重新输入正确的选项数字 [0-6]！"
    sleep 1.5
done

case "$NumberInput" in
    1|2|3)
        install_deps
        get_local_ips
        readp "请输入注册邮箱 (直接回车全自动生成8位随机Gmail): " INPUT_EMAIL
        if [ -z "$INPUT_EMAIL" ]; then
            Aemail="$(date +%s%N | md5sum | cut -c 1-8)@gmail.com"
            yellow "已生成随机邮箱: ${Aemail}"
        else
            Aemail="$INPUT_EMAIL"
        fi
        init_acme_core "$Aemail"
        stop_80_port
        ;;
esac

case "$NumberInput" in
    1 )  # 域名证书
        readp "请输入解析完成的域名: " DOMAIN
        [[ -z "$DOMAIN" ]] && red "域名不能为空！" && exit 1
        green "开始申请域名证书..."
        $ACME_BIN --set-default-ca --server letsencrypt
        if [[ "$DOMAIN" == *:* ]]; then
            $ACME_BIN --issue -d "$DOMAIN" --standalone -k ec-256 --listen-v6 --force --insecure
        else
            $ACME_BIN --issue -d "$DOMAIN" --standalone -k ec-256 --force --insecure
        fi
        [ $? -eq 0 ] && archive_and_display_output "$DOMAIN"
        ;;
        
    2 )  # IP证书
        yellow "VPS本地的IP：${vpsip}"
        readp "请输入申请IP证书的IP【格式：IPV4或者IPV6或者IPV4 IPV6，回车跳过使用${v4_local:-$v6_local}】: " INPUT_IP
        TARGET_IP=${INPUT_IP:-${v4_local:-$v6_local}}
        green "开始申请IP证书（使用LetsEncrypt）..."
        if [[ "$TARGET_IP" == *:* ]]; then
            $ACME_BIN --issue -d "$TARGET_IP" --standalone -k ec-256 --listen-v6 --server letsencrypt --cert-profile shortlived --days 3 --force --insecure
        else
            $ACME_BIN --issue -d "$TARGET_IP" --standalone -k ec-256 --server letsencrypt --cert-profile shortlived --days 3 --force --insecure
        fi
        [ $? -eq 0 ] && archive_and_display_output "$TARGET_IP"
        ;;
        
    3 )  # DNS API
        readp "请输入解析完成的域名: " DOMAIN
        [[ -z "$DOMAIN" ]] && red "域名不能为空！" && exit 1
        green "已输入的域名: $DOMAIN"
        green "开始DNS API模式申请..."
        
        echo
        yellow "请选择托管域名解析服务商："
        yellow "1. Cloudflare"
        yellow "2. 腾讯云 DNSPod"
        yellow "3. 阿里云 Aliyun"
        readp "请选择 [1-3]: " cd
        
        case "$cd" in
            1)
                yellow "请选择 Cloudflare 验证方式："
                yellow "1. API Token (推荐)"
                yellow "2. Global API Key"
                readp "请选择 [1-2]: " cf_choice
                if [ "$cf_choice" = "1" ]; then
                    readp "请输入 Cloudflare Account ID: " CFAccountID
                    export CF_Account_ID="$CFAccountID"
                    readp "请输入 Cloudflare DNS API Token: " CFToken
                    export CF_Token="$CFToken"
                else
                    readp "请输入 Cloudflare 邮箱: " CFemail
                    export CF_Email="$CFemail"
                    readp "请输入 Global API Key: " GAK
                    export CF_Key="$GAK"
                fi
                $ACME_BIN --issue --dns dns_cf -d "$DOMAIN" -k ec-256 --server letsencrypt --insecure
                ;;
            2)
                readp "请输入 DNSPod DP_Id: " DPID
                export DP_Id="$DPID"
                readp "请输入 DNSPod DP_Key: " DPKEY
                export DP_Key="$DPKEY"
                $ACME_BIN --issue --dns dns_dp -d "$DOMAIN" -k ec-256 --server letsencrypt --insecure
                ;;
            3)
                readp "请输入阿里云 Ali_Key: " ALKEY
                export Ali_Key="$ALKEY"
                readp "请输入阿里云 Ali_Secret: " ALSER
                export Ali_Secret="$ALSER"
                $ACME_BIN --issue --dns dns_ali -d "$DOMAIN" -k ec-256 --server letsencrypt --insecure
                ;;
        esac
        [ $? -eq 0 ] && archive_and_display_output "$DOMAIN"
        ;;
        
    4 )  # 查询证书
        show_cert_list
        ;;
        
    5 )  # 手动续期
        if [ ! -f "$ACME_BIN" ]; then
            red "未安装 acme.sh！" && exit 1
        fi
        green "正在手动一键证书续期..."
        stop_80_port
        $ACME_BIN --cron -f
        green "证书续期完成！"
        ;;
        
    6 )  # 卸载
        red "=================================================="
        red " 警告：该操作将彻底清空所有现存证书及自动续签任务！"
        red "=================================================="
        readp "确定要彻底删除证书并卸载脚本吗？(输入 y 确认 / 其他任意键取消): " DEL_CONFIRM
        if [[ "$DEL_CONFIRM" == "y" || "$DEL_CONFIRM" == "Y" ]]; then
            if [ -f "$ACME_BIN" ]; then
                $ACME_BIN --uninstall >/dev/null 2>&1
            fi
            rm -rf /root/.acme.sh "$WORK_DIR" /root/.xsjca_deps_done
            crontab -l 2>/dev/null | grep -v 'acme.sh --cron' > /tmp/cron.tmp && crontab /tmp/cron.tmp
            green "卸载完成！"
        fi
        ;;
        
    0 )
        exit 0
        ;;
esac

exit 0