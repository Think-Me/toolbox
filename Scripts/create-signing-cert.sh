#!/bin/bash
# 创建一把本地自签代码签名证书，让 TCC 授权在反复重建后依然有效。
#
# 为什么需要：ad-hoc 签名（codesign -s -）的 designated requirement 是
#   cdhash H"..."
# 每次重新编译 cdhash 都变，于是"辅助功能/屏幕录制"授权一次生效一次，
# 开发期等于每改一行代码就要重新勾一遍。换成有稳定身份的证书后，
# DR 变成按 identifier + 证书身份匹配，重建不再掉授权。
set -euo pipefail
cd "$(dirname "$0")/.."

CN="Toolbox Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CN"; then
    echo "已存在证书 \"$CN\"，跳过创建"
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/O=LocalDev/CN=$CN" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

openssl pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout pass: 2>/dev/null

# -T 授权 codesign 静默使用私钥，否则每次签名都会弹钥匙串授权框
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "" -T /usr/bin/codesign >/dev/null

# 不设 partition list 的话，codesign 仍会弹"xxx 想要使用钥匙串中的密钥"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || \
    echo "⚠️ set-key-partition-list 失败（登录钥匙串密码非空时会这样），签名时可能弹一次授权框"

security find-identity -v -p codesigning | grep "$CN" && echo "✅ 证书就绪：$CN"
