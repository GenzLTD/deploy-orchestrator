# 106-deploy-kit v2.3

目标机部署套件（nginx / systemd / .env / 账本 drop-in + 只读验收）。
入口文档是中文名的 `部署手册.md`（bootstrap kit v2.3）。**本包不含任何密钥值。**

## 解压

Linux 上的 Info-ZIP `unzip` 会把中文文件名解成乱码（`部署手册.md` → `щГич╜▓цЙЛхЖМ.md`），
包本身的 UTF-8 标志位是正确的。用下面任一种避开：

    python3 -m zipfile -e 106-deploy-kit-v2.3.zip .     # 推荐，按 UTF-8 正确解码
    bsdtar -xf 106-deploy-kit-v2.3.zip

macOS 双击解压、或 `unzip` 后手动改名，也都可以。

## 三条命令

    cd 106-deploy-kit && chmod +x bootstrap.sh
    bash tests/selfcheck.sh                            # 任意机器，先跑这个（8 项）
    sudo ./bootstrap.sh preflight                      # 目标机只读体检：0=可继续，2=有阻断，3=站错机器
    ./bootstrap.sh render --offline --out=/tmp/r       # 任意机器可跑，校对渲染结果

`preflight` / `infra` / `secrets` / `verify` **必须在目标 Linux 机上跑**；在 Mac 上跑会直接 `exit 3`。
`render` 不碰本机，可以随便跑。

## v2.3 只修一件事：Mac 自带 bash 3.2

`$VAR` 后面紧跟中文或全角标点时，bash 3.2 会把那几个字节当成变量名的一部分，`set -u` 下直接
`unbound variable`。v2.2 及以前因此**在 Mac 上跑不到**「站错机器 exit 3」那句，而是以退出码 1 死在
`bootstrap.sh:140`。v2.3 把全脚本这类展开统一改成 `${VAR}`，并在 `tests/selfcheck.sh` 里放了静态判据。

**单元模板、nginx 模板、渲染产物与 v2.2 逐字节相同**，106 上已装的那套不受影响；升级不需要重跑 `infra`。

## 必须先知道的（其余见手册）

- `infra` 幂等：内容没变就完全不动文件。`--dry-run` 的结论与真跑一致，可以用来预演。
- 106 在 2026-11-10 19:45 已真跑过一次 `infra`；现在再跑应当报「无变化」。
- 部署顺序是**核 → 宿主**，反过来会让新宿主调用旧核的接口。
- `verify` 会验账本落点（`DATABASE_PATH` 是否指向 `looma/data/looma.db`），不再只看端口。
- `BOOTSTRAP_HOST_OS` 是给 `tests/selfcheck.sh` 用的测试钩子，正常运行不要设。
