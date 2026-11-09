#!/bin/bash
# 署名用の自己署名証明書を作って、ログインキーチェーンに入れる。1台につき1回だけ実行する。
#
# これで署名すると、ビルドし直しても macOS から同じアプリとして扱われ、
# 画面収録とマイクの許可が引き継がれる（証明書が無いと、ビルドのたびに許可がやり直しになる）。
set -euo pipefail

NAME="Tsugumi Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "すでにあります: $NAME"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

cat > cert.cnf <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

# macOS 標準の openssl を使う（新しい OpenSSL が作る形式は、キーチェーンが読めないことがある）
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -out identity.p12 -passout pass:tsugumi -name "$NAME"
security import identity.p12 -k "$KEYCHAIN" -P tsugumi -T /usr/bin/codesign

echo "作成しました: $NAME"
echo "最初のビルドでキーチェーンの確認が出たら、「常に許可」を選んでください。"
