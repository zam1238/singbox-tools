# 环境变量说明

## ① uuid=XXXX-xxx-XXXX（可传，可不传）

**含义**
- 不传uuid → 脚本自动生成 UUID
- 传uuid → 使用你指定的 UUID

## ② argo（Cloudflare Argo 开关）

- 当argo=vmpt 表示启用vmess的argo转发
- 当argo=trpt 表示启用trojan的argo转发
- 或者这个argo参数留空，表示不启用argo

> ⚠️ Argo 只能用于 VMess / Trojan
> ❌ 对 hypt / vlrt 无效

## ③ agn / agk（Argo 固定隧道）

- agn="argo固定隧道域名"
- agk="argo隧道token"

**是否必须？**
- ❌ 不传 → 临时 Argo（trycloudflare）
- ✅ 只有你自己有 CF Tunnel才传

## ④ cf_host（cdn域名 和 cf_port） 注意：这2个值不会填的话就不要传

## 用在以上地方:
——VMess Argo：
"add":"${cf_host}"

—— Trojan Argo：
trojan://${uuid}@${cf_host}:cf_port?...




## ⑤ ippz（IP 优选策略，可选）

| 值 | 含义 |
|----|-----|
| 4  | 强制使用 IPv4 |
| 6  | 强制使用 IPv6 |
| 空 | 自动判断 |

> 👉 只影响 节点输出，不影响服务运行

## ⑥ name（节点名称前缀）

- 不传 → 默认 hostname
- 传 → 节点名前加前缀

**例子：**
- name=HK
- ➡ HK-vmess / HK-vless

# 常见组合调用方式

## 组合1️⃣ 仅 1 直连协议（不走 Argo,hypt与vlrt参数选一个来写）

### 只要hy2协议

```bash
hypt=2082 \
bash <(curl -Ls https://raw.githubusercontent.com/jyucoeng/singbox-tools/refs/heads/main/sb.sh)
```

### 只要vless Reality协议

```bash
vlrt=2083 \
bash <(curl -Ls https://raw.githubusercontent.com/jyucoeng/singbox-tools/refs/heads/main/sb.sh)
```

## 组合2️⃣ 仅 2 直连协议（不走 Argo,hypt与vlrt参数都写代表hy2和vless-reality 协议都会出来）

```bash
hypt=2082 \
vlrt=2083 \
bash <(curl -Ls https://raw.githubusercontent.com/jyucoeng/singbox-tools/refs/heads/main/sb.sh)
```

## 组合3️⃣ VMess  Argo/ Trojan  Argo（最常用，2个协议选一个）

```bash
ippz=4 \
trpt=31003 \
argo=trpt \
agn="test-trojan.xxxx.xyz" \
agk="eyJhIjoiYTg2NTc2M21111wdsdwdwdwWRiZmMxYzJkYzRlYTYiLCJ0IjoiZDgyYzk3MmItZGNlNy00ODJkLWI2NjgtYmJlNDgyZDMxNTNhIiwicyI6IlkyRmhNbVkxTURVdFlUZ3lPQzAwTVRBMExUbGhNakV0TUdNd1pXVmlORFF4WWpobCJ9" \
name="小叮当-韩国春川"  \
bash <(curl -Ls https://raw.githubusercontent.com/jyucoeng/singbox-tools/refs/heads/main/sb.sh)
```

### 当使用trojan的argo时

```bash
ippz=4 \
trpt=31003 \
argo=trpt \
agn="test-trojan.xxxx.xyz" \
agk="eyJhIjoiYTg2NTc2M21111wdsdwdwdwWRiZmMxYzJkYzRlYTYiLCJ0IjoiZDgyYzk3MmItZGNlNy00ODJkLWI2NjgtYmJlNDgyZDMxNTNhIiwicyI6IlkyRmhNbVkxTURVdFlUZ3lPQzAwTVRBMExUbGhNakV0TUdNd1pXVmlORFF4WWpobCJ9" \
name="小叮当-韩国春川"  \
bash <(curl -Ls https://raw.githubusercontent.com/jyucoeng/singbox-tools/refs/heads/main/sb.sh) rep
```

## 当使用trojan的argo时

```bash
ippz=4 \
trpt=31003 \
argo=trpt \
agn="test-vmess.xxxx.xyz" \
agk="eyJhIjoiYTg2NTc2M20000wdsdwdwdwWRiZmMxYzJkYzRlYTYiLCJ0IjoiZDgyYzk3MmItZGNlNy00ODJkLWI2NjgtYmJlNDgyZDMxNTNhIiwicyI6IlkyRmhNbVkxTURVdFlUZ3lPQzAwTVRBMExUbGhNakV0TUdNd1pXVmlORFF4WWpobCJ9" \
name="小叮当-韩国春川"  \
bash <(curl -Ls https://raw.githubusercontent.com/jyucoeng/singbox-tools/refs/heads/main/sb.sh) rep
```

## 4️⃣ VMess + Hysteria2+ vless

```bash
ippz=4 \
hypt=31001 \
vlrt=31002 \
vmpt=31003 \
argo=vmpt \
agn="test-vmess.xx66.nyc.mn" \
agk="eyJhIjoiYTg2NTc2M2YxOGEwOTZhOWI3MWRiZmMxYzJkYzRlYTYiLCJ0IjoiOTQzNzM0ZGUtOGQ5Ni00MmNkLThhMTQtNzE0ODJjMTg2ODlmIiwicyI6IlltRXhNakk1WXpVdE56TXhaQzAwWVRrd0xUa3dNR1l0T0dNek9HWXpZekk1TkRGbCJ9" \
name="小叮当-韩国春川"  \
bash <(curl -Ls https://raw.githubusercontent.com/jyucoeng/singbox-tools/refs/heads/main/sb.sh) rep
```

## 以此类推

| 你设置了什么             | 实际生成的节点        |
| ------------------ | -------------- |
| hypt               | 1（hy2）         |
| vlrt               | 1（vless）       |
| vmpt               | 0（无直连）         |
| trpt               | 0（无直连）         |
| vmpt + argo=vmpt   | 1（Argo-vmess）  |
| trpt + argo=trpt   | 1（Argo-trojan） |
| hypt + vlrt        | 2（直连）          |
| hypt + vlrt + argo | **3（最大）**      |
