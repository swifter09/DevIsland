#!/bin/bash
# 创建稳定的自签名 Code Signing 证书「DevIsland Local」并导入登录钥匙串。
#
# 为什么需要：
#   ad-hoc 签名（codesign -s -）每次重建签名都变，macOS 会把已授予的权限
#   （辅助功能等）重置，导致反复弹权限请求。用一个固定的自签名证书签名后，
#   签名标识稳定，权限可长期保持。
#
# 幂等：已存在同名证书则直接退出，不重复创建。换新机器时跑一次即可。
set -euo pipefail

CERT_NAME="DevIsland Local"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"

# 已存在就跳过
if security find-identity -p codesigning "$LOGIN_KC" 2>/dev/null | grep -q "\"$CERT_NAME\""; then
    echo "==> 证书「${CERT_NAME}」已存在，无需创建。"
    security find-identity -p codesigning "$LOGIN_KC" | grep "\"$CERT_NAME\""
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PW="devisland"  # p12 临时口令，仅用于导入过程

echo "==> 生成自签名证书（codeSigning 用途，10 年有效）"
cat > "$WORK/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = $CERT_NAME
[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -config "$WORK/cert.cnf"

# 打包成 p12（macOS 自带的 LibreSSL 默认算法即与钥匙串兼容；需带口令）
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$CERT_NAME" -out "$WORK/cert.p12" -passout "pass:$PW"

echo "==> 导入登录钥匙串，并授权 codesign 免提示访问私钥"
security import "$WORK/cert.p12" -k "$LOGIN_KC" -P "$PW" \
    -T /usr/bin/codesign -T /usr/bin/security

echo "==> 完成。当前 codesigning 身份："
security find-identity -p codesigning "$LOGIN_KC" | grep "\"$CERT_NAME\"" || true

echo
echo "提示：证书标记 CSSMERR_TP_NOT_TRUSTED 属正常（自签名无受信任根背书），"
echo "      不影响本地签名与启动。现在可运行 ./scripts/build_app.sh。"
