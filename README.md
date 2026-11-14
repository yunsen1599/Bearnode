# NPanel-node

A NPanel node server based on xray-core, modified from v2node.  
一个基于xray内核的NPanel节点服务端，修改自v2node

## 软件安装

### 一键安装

```
wget -N https://raw.githubusercontent.com/yunsen1599/NPnode-release/main/scripts/install.sh && bash install.sh
```

## 构建
``` bash
GOEXPERIMENT=jsonv2 go build -v -o ./npnode -trimpath -ldflags "-s -w -buildid="
```

## 发布

源码仓库是私有的，安装脚本和安装包发布在公开仓库 [yunsen1599/NPnode-release](https://github.com/yunsen1599/NPnode-release)，节点服务器无需任何凭据即可一键安装和更新。

``` bash
scripts/release.sh 1.0.5
```

脚本会编译 linux 64 / arm64-v8a / s390x 安装包，把 `scripts/install.sh`、`scripts/npnode.sh`、`README.md` 同步到发布仓库，创建同名 Release，并在源码仓库打 tag。
